const edgeJose = 'https://esm.sh/jose@5.10.0';

export async function resolve(specifier, context, nextResolve) {
  return nextResolve(specifier === edgeJose ? 'jose' : specifier, context);
}
