const mongoose = require("mongoose");

const TransactionSchema = new mongoose.Schema({
  from: String,
  to: String,
  amount: String,
  hash: String,
  createdAt: { type: Date, default: Date.now }
});

module.exports = mongoose.model("Transaction", TransactionSchema);
