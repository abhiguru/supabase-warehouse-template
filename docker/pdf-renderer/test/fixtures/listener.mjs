// A tiny TCP/HTTP listener that logs every connection. The renderer must never reach it.
import http from 'node:http';
const server = http.createServer((req, res) => { console.log(`HIT ${req.method} ${req.url}`); res.end('ok'); });
server.on('connection', () => console.log('CONN'));
server.on('upgrade', (req, socket) => { console.log(`UPGRADE ${req.url}`); socket.destroy(); });
server.listen(8080, '0.0.0.0', () => console.log('LISTENING'));
