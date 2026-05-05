/* eslint-disable @typescript-eslint/no-require-imports */
const fs = require('fs');
const https = require('https');

const SUPABASE_URL = 'https://kzprtthvbptllyvebmgk.supabase.co';
const DB_PASSWORD = 'Soumya@2842y';

// Read the combined migrations file
const sql = fs.readFileSync('./supabase/.temp/all_migrations.sql', 'utf-8');

// Split into chunks of ~50KB to avoid request size limits
const statements = sql.split(/;\s*\n/);
const chunks = [];
let currentChunk = '';

for (const stmt of statements) {
  const trimmed = stmt.trim();
  if (!trimmed || trimmed.startsWith('--')) continue;
  
  if (currentChunk.length + trimmed.length > 40000) {
    chunks.push(currentChunk);
    currentChunk = '';
  }
  currentChunk += trimmed + ';\n';
}
if (currentChunk.trim()) chunks.push(currentChunk);

console.log(`Total SQL: ${sql.length} bytes`);
console.log(`Split into ${chunks.length} chunks`);

async function runSQL(sqlText, chunkIndex) {
  return new Promise((resolve, reject) => {
    // const url = new URL(`${SUPABASE_URL}/rest/v1/rpc/exec_sql`);
    
    // Use the postgres connection directly via pg wire protocol
    // Since REST API won't work for DDL, let's use the SQL API
    const postData = JSON.stringify({ query: sqlText });
    
    const options = {
      hostname: 'kzprtthvbptllyvebmgk.supabase.co',
      port: 443,
      path: '/pg/query',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        'Authorization': 'Basic ' + Buffer.from(`postgres:${DB_PASSWORD}`).toString('base64'),
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          console.log(`Chunk ${chunkIndex + 1}/${chunks.length}: OK`);
          resolve(data);
        } else {
          console.error(`Chunk ${chunkIndex + 1}/${chunks.length}: HTTP ${res.statusCode}`);
          console.error(data.substring(0, 500));
          reject(new Error(`HTTP ${res.statusCode}`));
        }
      });
    });

    req.on('error', (e) => {
      console.error(`Chunk ${chunkIndex + 1}: Network error: ${e.message}`);
      reject(e);
    });

    req.write(postData);
    req.end();
  });
}

(async () => {
  for (let i = 0; i < chunks.length; i++) {
    try {
      await runSQL(chunks[i], i);
    } catch (_e) {
      console.error(`Failed at chunk ${i + 1}. Stopping.`);
      process.exit(1);
    }
  }
  console.log('\nAll migrations applied successfully!');
})();
