
require('dotenv').config();
const { Telegraf } = require('telegraf');

const bot = new Telegraf(process.env.TELEGRAM_BOT_TOKEN);

bot.start((ctx) => ctx.reply('Welcome to TGST! Use /help for commands.'));
bot.command('help', (ctx) => ctx.reply('/start, /help, /ping, /about'));
bot.command('ping', (ctx) => ctx.reply('pong'));
bot.command('about', (ctx) => ctx.reply('TGST: Global rewards on your everyday spend.'));

bot.launch().then(() => console.log('TGST bot started.'));
process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
