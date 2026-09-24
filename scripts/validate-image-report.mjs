import { readFileSync } from 'node:fs';

const [path, image] = process.argv.slice(2);
try {
  const report = JSON.parse(readFileSync(path, 'utf8'));
  if (report.SchemaVersion !== 2 || report.ArtifactName !== image ||
      report.ArtifactType !== 'container_image' ||
      !Array.isArray(report.Results) || report.Results.length === 0) {
    throw new Error('missing or mismatched container scan evidence');
  }
  for (const result of report.Results) {
    if (!result.Target || !['os-pkgs', 'lang-pkgs'].includes(result.Class) ||
        !Array.isArray(result.Packages) ||
        !result.Packages.some(pkg => typeof pkg?.Name === 'string' && pkg.Name.length > 0 &&
          typeof pkg.Version === 'string' && pkg.Version.length > 0) ||
        (result.Vulnerabilities !== undefined && !Array.isArray(result.Vulnerabilities))) {
      throw new Error('invalid vulnerability result or missing versioned package inventory');
    }
    if (result.Vulnerabilities?.some(v => ['HIGH', 'CRITICAL'].includes(v.Severity))) {
      throw new Error('HIGH/CRITICAL vulnerabilities remain');
    }
  }
} catch (error) {
  console.error(`Image scan evidence rejected for ${image}: ${error.message}`);
  process.exitCode = 1;
}
