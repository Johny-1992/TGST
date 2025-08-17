
const express = require('express');
const cors = require('cors');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => res.json({ ok: true, service: 'tgst-backend' }));

app.post('/webhook/partner', (req, res) => {
  // verify secret
  if (req.headers['x-webhook-secret'] !== process.env.WEBHOOK_SECRET) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  // process payload from partner (usage, recharge, etc.)
  // map to user wallet/account and store accounting
  console.log('Partner payload', req.body);
  return res.json({ ok: true });
});

const port = process.env.PORT || 3001;
app.listen(port, () => console.log(`TGST backend running on :${port}`));
