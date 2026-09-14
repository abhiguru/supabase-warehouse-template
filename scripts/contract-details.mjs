import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { spawnSync } from 'node:child_process';

export function details(mobile, sourceFiles, backend, live = false) {
  const ts = createRequire(resolve(mobile, 'package.json'))('typescript');
  const program = ts.createProgram(sourceFiles, { noEmit: true, allowJs: false, target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, baseUrl: mobile, paths: { '@/*': ['src/*'] }, skipLibCheck: true });
  const checker = program.getTypeChecker();
  const calls = [];
  const dynamic = [];
  for (const source of program.getSourceFiles().filter(s => sourceFiles.includes(s.fileName))) {
    const visit = node => {
      if (ts.isCallExpression(node)) {
        const property = ts.isPropertyAccessExpression(node.expression) ? node.expression.name.text : '';
        const identifier = ts.isIdentifier(node.expression) ? node.expression.text : '';
        const index = identifier === 'executeRPC' ? 1 : (property === 'rpc' || ['boundedAuthRPC', 'callRPC'].includes(identifier)) ? 0 : -1;
        if (index >= 0 && node.arguments[index]) {
          const expression = node.arguments[index];
          const location = `${relative(mobile, source.fileName)}:${source.getLineAndCharacterOfPosition(node.pos).line + 1}`;
          const type = checker.getTypeAtLocation(expression);
          const types = type.isUnion() ? type.types : [type];
          const names = types.filter(t => t.isStringLiteral()).map(t => t.value);
          let argument = node.arguments[index + 1];
          while (argument && (ts.isAsExpression(argument) || ts.isTypeAssertionExpression(argument) || ts.isNonNullExpression(argument))) argument = argument.expression;
          const fields = argument ? checker.getTypeAtLocation(argument).getProperties().map(p => p.name).filter(n => !n.startsWith('__')) : [];
          // Recover named keys from Record/any builders without evaluating mobile code.
          if (argument && ts.isIdentifier(argument) && fields.length === 0) {
            const symbol = checker.getSymbolAtLocation(argument);
            const declaration = symbol?.valueDeclaration;
            if (declaration && ts.isVariableDeclaration(declaration) && declaration.initializer) {
              for (const property of checker.getTypeAtLocation(declaration.initializer).getProperties()) fields.push(property.name);
            }
            const collect = child => {
              if (ts.isBinaryExpression(child) && child.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isPropertyAccessExpression(child.left) && checker.getSymbolAtLocation(child.left.expression) === symbol) fields.push(child.left.name.text);
              ts.forEachChild(child, collect);
            };
            collect(source);
          }
          const unknownArgs = !!argument && fields.length === 0 && argument.getText(source) !== '{}';
          for (const name of names) calls.push({ name, location, arguments: [...new Set(fields)].sort(), unknownArguments: unknownArgs });
          if (!names.length) dynamic.push({ location, expression: expression.getText(source), arguments: fields });
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  const result = { calls, dynamic, signatures: [], mismatches: [] };
  if (live) {
    const query = `SELECT json_agg(json_build_object('name',p.proname,'identity',p.oid::regprocedure::text,'arguments',COALESCE(p.proargnames[1:p.pronargs],ARRAY[]::text[]),'required',p.pronargs-p.pronargdefaults,'result',pg_get_function_result(p.oid),'anonymous',has_function_privilege('anon',p.oid,'EXECUTE'),'authenticated',has_function_privilege('authenticated',p.oid,'EXECUTE'))) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace;`;
    const response = spawnSync('bash', [resolve(backend, 'scripts/compose.sh'), 'exec', '-T', 'db', 'psql', '-XAt', '-U', 'supabase_admin', '-d', 'postgres', '-c', query], { encoding: 'utf8', timeout: 30000 });
    if (response.status !== 0) throw new Error('Ownership-checked live contract catalog unavailable.');
    const catalog = JSON.parse(response.stdout);
    result.signatures = catalog.filter(s => calls.some(c => c.name === s.name));
    for (const call of calls.filter(c => !c.unknownArguments)) {
      const matches = catalog.filter(s => s.name === call.name && s.authenticated && call.arguments.every(a => s.arguments.includes(a)) && s.arguments.slice(0, s.required).every(a => call.arguments.includes(a)));
      if (matches.length !== 1) result.mismatches.push({ ...call, matchingOverloads: matches.length });
    }
  }
  return result;
}
