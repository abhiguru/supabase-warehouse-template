import { serve } from 'https://deno.land/std@0.192.0/http/server.ts'
import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

console.log('main function started')

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) {
    throw new Error('Missing authorization header')
  }
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') {
    throw new Error(`Auth header is not 'Bearer {token}'`)
  }
  return token
}

async function verifyJWT(jwt: string): Promise<boolean> {
  const encoder = new TextEncoder()
  const secretKey = encoder.encode(JWT_SECRET)
  try {
    await jose.jwtVerify(jwt, secretKey)
  } catch (err) {
    console.error(err)
    return false
  }
  return true
}

serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    try {
      const token = getAuthToken(req)
      const isValidJWT = await verifyJWT(token)

      if (!isValidJWT) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      console.error(e)
      return new Response(JSON.stringify({ msg: e.toString() }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  const url = new URL(req.url)
  const { pathname } = url
  const path_parts = pathname.split('/')
  const service_name = path_parts[1]

  if (!service_name || service_name === '') {
    const error = { msg: 'missing function name in request' }
    return new Response(JSON.stringify(error), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const eszipPath = `/home/deno/bundles/${service_name}.eszip`
  const servicePath = `/home/deno/functions/${service_name}`

  const memoryLimitMb = 150
  const workerTimeoutMs = 1 * 60 * 1000
  const noModuleCache = false
  const importMapPath = null
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  let worker
  let usingBundle = false

  try {
    const stat = await Deno.stat(eszipPath)
    if (stat.isFile) {
      const eszipBytes = await Deno.readFile(eszipPath)
      console.error(`[BUNDLE] Loading ${service_name} from eszip (${eszipBytes.length} bytes)`)
      worker = await EdgeRuntime.userWorkers.create({
        servicePath,
        maybeEszip: eszipBytes,
        maybeEntrypoint: 'file:///src/index.ts',
        memoryLimitMb,
        workerTimeoutMs,
        noModuleCache,
        envVars,
      })
      usingBundle = true
    }
  } catch (bundleError) {
    console.error(`[DEGRADED] Bundle load failed for ${service_name}: ${bundleError}`)
    console.error(`[DEGRADED] Falling back to source - expect slow cold start`)
  }

  if (!worker) {
    try {
      console.error(`[SOURCE] Loading ${service_name} from ${servicePath}`)
      worker = await EdgeRuntime.userWorkers.create({
        servicePath,
        memoryLimitMb,
        workerTimeoutMs,
        noModuleCache,
        importMapPath,
        envVars,
      })
    } catch (e) {
      const error = { msg: e.toString() }
      return new Response(JSON.stringify(error), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  return await worker.fetch(req)
})
