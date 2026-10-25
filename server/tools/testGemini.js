const fs = require('node:fs');
const { connectClient } = require('./client');

async function main() {
  const filename = process.argv[2];
  if (!filename) throw new Error('Usage: node tools/testGemini.js <test-photo.jpg>');
  const photo = fs.readFileSync(filename).toString('base64');
  const client = await connectClient(process.env.WS_URL || 'ws://127.0.0.1:8080/ws');
  try {
    client.send({ t: 'create', name: 'Gemini test host' });
    await client.waitFor((event) => event.t === 'joined');
    client.send({ t: 'suggest', photos: [photo] });
    const result = await client.waitFor((event) => event.t === 'suggestions', 60000);
    if (!result.objects.length) throw new Error('No objects detected. Try a clear photo with ordinary objects.');
    console.log(JSON.stringify(result, null, 2));
    console.log(`PASS: live Gemini returned ${result.objects.length} labeled image boxes.`);
  } finally {
    client.socket.close();
  }
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
