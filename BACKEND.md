# TGST Backend Notes

- `server.js` doit inclure :

```js
const connectDB = require("./config/database");
connectDB();
```

- Les modèles disponibles : `User`, `Transaction`
- Variables Render nécessaires :
  - `MONGO_URI`
  - `PRIVATE_KEY`
  - `BSC_TESTNET_RPC`
  - `FEE_COLLECTOR`
