#!/usr/bin/env node
// Generates the brand icons shown instead of a letter for well-known sites and apps, plus the lookup tables that match
// a record's "Website/App name" or name to them (Android: BrandIcons.kt, iOS: BrandIcons.swift). Run it only to change the list below.
//
//   mkdir /tmp/brandgen && (cd /tmp/brandgen && npm init -y && npm i simple-icons @resvg/resvg-js)
//   BRANDGEN_DIR=/tmp/brandgen node scripts/generate-brand-icons.mjs
//
// Icon source, in order of preference for each brand:
//   1. assets/brand-icons/<id>.jpg, the brand's official app icon. Fetch missing ones with `--fetch` (uses Apple's public iTunes lookup
//      API, records where each came from in assets/brand-icons/sources.json). Delete or replace a file to change what is used.
//   2. the brand's logo from Simple Icons (CC0) on a brand-colored tile, and
//   3. a lettered tile in the brand's approximate color (for brands with neither).
// Logos come from the Simple Icons project (CC0). The names and logos remain trademarks of their owners; they are shown only
// to identify the service a saved login belongs to. Brands Simple Icons no longer carries are skipped and reported.
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync, rmSync, readdirSync, existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = process.env.BRANDGEN_DIR || die('Set BRANDGEN_DIR to a folder where `npm i simple-icons @resvg/resvg-js` was run.')
const require = createRequire(join(dir, 'x.js'))
const icons = require('simple-icons'), { Resvg } = require('@resvg/resvg-js')
const root = join(dirname(fileURLToPath(import.meta.url)), '..')
function die(m) { console.error(m); process.exit(1) }

// [Simple Icons slug, domains (a login on any subdomain matches), extra names people type]
const BRANDS = [
  ['google', ['google.com', 'gmail.com', 'googlemail.com'], ['gmail']], ['youtube', ['youtube.com', 'youtu.be']], ['github', ['github.com']], ['gitlab', ['gitlab.com']],
  ['bitbucket', ['bitbucket.org']], ['apple', ['apple.com', 'icloud.com'], ['icloud', 'apple id']], ['microsoft', ['microsoft.com', 'live.com', 'outlook.com', 'office.com', 'microsoftonline.com'], ['outlook', 'office 365', 'hotmail']],
  ['amazon', ['amazon.com', 'amazon.co.uk', 'amazon.de', 'amazon.co.jp', 'amazon.ca', 'amazon.cn']], ['amazonaws', ['aws.amazon.com', 'amazonaws.com'], ['aws', 'amazon web services']],
  ['facebook', ['facebook.com', 'fb.com'], ['fb']], ['instagram', ['instagram.com']], ['x', ['x.com', 'twitter.com'], ['twitter']], ['threads', ['threads.net']], ['reddit', ['reddit.com']],
  ['linkedin', ['linkedin.com']], ['pinterest', ['pinterest.com']], ['snapchat', ['snapchat.com']], ['tiktok', ['tiktok.com']], ['tumblr', ['tumblr.com']], ['whatsapp', ['whatsapp.com']],
  ['telegram', ['telegram.org', 't.me']], ['signal', ['signal.org']], ['discord', ['discord.com', 'discord.gg']], ['slack', ['slack.com']], ['zoom', ['zoom.us']], ['skype', ['skype.com']],
  ['wechat', ['wechat.com', 'weixin.qq.com'], ['weixin', '微信']], ['line', ['line.me']], ['viber', ['viber.com']],
  ['netflix', ['netflix.com']], ['spotify', ['spotify.com']], ['twitch', ['twitch.tv']], ['soundcloud', ['soundcloud.com']], ['disneyplus', ['disneyplus.com'], ['disney+', 'disney plus']],
  ['hulu', ['hulu.com']], ['primevideo', ['primevideo.com'], ['prime video', 'amazon prime']], ['hbo', ['hbo.com']], ['crunchyroll', ['crunchyroll.com']], ['vimeo', ['vimeo.com']], ['bilibili', ['bilibili.com']],
  ['notion', ['notion.so', 'notion.com']], ['dropbox', ['dropbox.com']], ['evernote', ['evernote.com']], ['trello', ['trello.com']], ['atlassian', ['atlassian.com', 'atlassian.net'], ['jira', 'confluence']],
  ['figma', ['figma.com']], ['canva', ['canva.com']], ['adobe', ['adobe.com']], ['asana', ['asana.com']], ['airtable', ['airtable.com']], ['miro', ['miro.com']], ['box', ['box.com']],
  ['cloudflare', ['cloudflare.com']], ['digitalocean', ['digitalocean.com']], ['heroku', ['heroku.com']], ['vercel', ['vercel.com']], ['netlify', ['netlify.com', 'netlify.app']],
  ['docker', ['docker.com', 'docker.io']], ['npm', ['npmjs.com']], ['stackoverflow', ['stackoverflow.com', 'stackexchange.com'], ['stack overflow']], ['godaddy', ['godaddy.com']], ['namecheap', ['namecheap.com']],
  ['wordpress', ['wordpress.com', 'wordpress.org']], ['medium', ['medium.com']], ['substack', ['substack.com']], ['openai', ['openai.com', 'chatgpt.com'], ['chatgpt']], ['anthropic', ['anthropic.com', 'claude.ai'], ['claude']],
  ['huggingface', ['huggingface.co'], ['hugging face']], ['kaggle', ['kaggle.com']], ['leetcode', ['leetcode.com']],
  ['binance', ['binance.com', 'binance.us']], ['coinbase', ['coinbase.com']], ['kraken', ['kraken.com']], ['okx', ['okx.com']], ['bybit', ['bybit.com']], ['kucoin', ['kucoin.com']], ['bitcoin', ['bitcoin.org']],
  ['ethereum', ['ethereum.org']], ['metamask', ['metamask.io']], ['ledger', ['ledger.com']], ['trezor', ['trezor.io']], ['tether', ['tether.to']],
  ['paypal', ['paypal.com']], ['stripe', ['stripe.com']], ['wise', ['wise.com', 'transferwise.com'], ['transferwise']], ['revolut', ['revolut.com']], ['visa', ['visa.com']], ['mastercard', ['mastercard.com']],
  ['americanexpress', ['americanexpress.com', 'amex.com'], ['amex', 'american express']], ['alipay', ['alipay.com']], ['wechatpay', ['pay.weixin.qq.com'], ['wechat pay']], ['cashapp', ['cash.app'], ['cash app']], ['venmo', ['venmo.com']],
  ['bitwarden', ['bitwarden.com']], ['1password', ['1password.com'], ['onepassword']], ['lastpass', ['lastpass.com']], ['dashlane', ['dashlane.com']], ['proton', ['proton.me', 'protonmail.com', 'protonvpn.com'], ['protonmail', 'proton mail']],
  ['nordvpn', ['nordvpn.com']], ['expressvpn', ['expressvpn.com']], ['mega', ['mega.nz', 'mega.io']], ['icloud', ['icloud.com']], ['yahoo', ['yahoo.com', 'ymail.com']], ['duckduckgo', ['duckduckgo.com']],
  ['steam', ['steampowered.com', 'steamcommunity.com']], ['epicgames', ['epicgames.com'], ['epic games']], ['playstation', ['playstation.com', 'sonyentertainmentnetwork.com'], ['psn', 'playstation network']],
  ['nintendo', ['nintendo.com']], ['xbox', ['xbox.com']], ['ea', ['ea.com'], ['electronic arts']], ['ubisoft', ['ubisoft.com']], ['riotgames', ['riotgames.com', 'leagueoflegends.com'], ['riot games']], ['battledotnet', ['battle.net', 'blizzard.com'], ['battle.net', 'blizzard']],
  ['ebay', ['ebay.com']], ['aliexpress', ['aliexpress.com']], ['alibabadotcom', ['alibaba.com'], ['alibaba']], ['taobao', ['taobao.com']], ['shopify', ['shopify.com']], ['etsy', ['etsy.com']], ['walmart', ['walmart.com']],
  ['target', ['target.com']], ['ikea', ['ikea.com']], ['nike', ['nike.com']], ['adidas', ['adidas.com']], ['uber', ['uber.com']], ['lyft', ['lyft.com']], ['airbnb', ['airbnb.com']], ['bookingdotcom', ['booking.com'], ['booking']],
  ['tripadvisor', ['tripadvisor.com']], ['expedia', ['expedia.com']], ['grab', ['grab.com']], ['doordash', ['doordash.com']], ['deliveroo', ['deliveroo.com']],
  ['tesla', ['tesla.com']], ['samsung', ['samsung.com']], ['huawei', ['huawei.com']], ['xiaomi', ['mi.com', 'xiaomi.com']], ['sony', ['sony.com']], ['nvidia', ['nvidia.com']], ['intel', ['intel.com']], ['amd', ['amd.com']],
  ['synology', ['synology.com', 'quickconnect.to'], ['dsm', 'synology nas', 'synology dsm']],
  ['chase', ['chase.com', 'jpmorgan.com', 'jpmorganchase.com'], ['jp morgan', 'jpmorgan', 'chase bank']], ['bankofamerica', ['bankofamerica.com', 'bofa.com', 'merrilledge.com'], ['bofa', 'bank of america']],
  ['wellsfargo', ['wellsfargo.com'], ['wells fargo']], ['discover', ['discover.com']], ['goldmansachs', ['goldmansachs.com', 'marcus.com'], ['goldman sachs', 'marcus']],
  ['hsbc', ['hsbc.com', 'hsbc.com.hk', 'hsbc.com.cn', 'hsbc.co.uk', 'us.hsbc.com'], ['hsbc hk', 'hsbc hong kong', '滙豐', '汇丰']], ['barclays', ['barclays.co.uk', 'barclays.com']],
  ['monzo', ['monzo.com']], ['nubank', ['nubank.com.br']], ['robinhood', ['robinhood.com']],
  ['uphold', ['uphold.com']], ['blockchaindotcom', ['blockchain.com'], ['blockchain.com', 'blockchain wallet']], ['walletconnect', ['walletconnect.com', 'walletconnect.org']],
  ['wasabi', ['wasabiwallet.io'], ['wasabi wallet']], ['opensea', ['opensea.io']],
  ['qq', ['qq.com']], ['baidu', ['baidu.com']], ['sinaweibo', ['weibo.com', 'weibo.cn'], ['weibo', '微博']], ['zhihu', ['zhihu.com']], ['douban', ['douban.com']],
]
// Banks and brokers Simple Icons doesn't carry: a tile in the approximate brand color with the usual abbreviation, not the logo.
// [id, tile color, mark, names people type, domains]
const MONOGRAMS = [
  // Crypto exchanges
  ['bitget', '00CFE8', 'Bitget', ['bitget wallet'], ['bitget.com', 'bitget.fit']], ['gateio', '2354E6', 'gate', ['gate.io', 'gate io', 'gate.com'], ['gate.io', 'gate.com', 'gateio.pro']],
  ['htx', '1A8CFF', 'HTX', ['huobi', 'huobi global', '火币'], ['htx.com', 'huobi.com', 'htx.com.pk']], ['mexc', '1972E2', 'MEXC', ['mxc'], ['mexc.com', 'mexc.io']],
  ['cryptocom', '002D74', 'CRO', ['crypto.com', 'crypto com', 'cryptocom'], ['crypto.com']], ['bitfinex', '16B157', 'bfx', [], ['bitfinex.com']], ['bitstamp', '1F9E4B', 'BS', [], ['bitstamp.net']],
  ['gemini', '00DCFA', 'G', ['gemini exchange', 'gemini crypto'], ['gemini.com']], ['upbit', '093687', 'UP', ['업비트'], ['upbit.com']], ['bithumb', 'F37321', 'BT', ['빗썸'], ['bithumb.com']],
  ['coincheck', '0E2A5C', 'CC', [], ['coincheck.com']], ['bitflyer', '1A56DB', 'bF', [], ['bitflyer.com', 'bitflyer.jp']], ['bitpanda', '0FB58D', 'BP', [], ['bitpanda.com']],
  ['bingx', '2A54FF', 'BingX', [], ['bingx.com']], ['bitmart', '1A1A1A', 'BM', [], ['bitmart.com']], ['lbank', '2E5BFF', 'LB', [], ['lbank.com', 'lbkex.com']],
  ['phemex', '6CE0A5', 'Phemex', [], ['phemex.com']], ['poloniex', '1E4D37', 'Polo', [], ['poloniex.com']], ['deribit', '1A1A2E', 'Dbit', [], ['deribit.com']],
  ['whitebit', '1C1C1C', 'WB', [], ['whitebit.com']], ['bitvavo', '0A5AF7', 'BV', [], ['bitvavo.com']], ['coinex', '4AD8AC', 'CoinEx', [], ['coinex.com']],
  ['okcoin', '1E60F4', 'OKC', [], ['okcoin.com']], ['etoro', '13C636', 'eToro', [], ['etoro.com']], ['maicoin', '0A50FF', 'MAX', ['max exchange', 'max maicoin', 'maicoin'], ['max.maicoin.com', 'maicoin.com']],
  ['bitopro', '00A0E9', 'BitoPro', [], ['bitopro.com']], ['osl', '0C0C4F', 'OSL', ['osl exchange'], ['osl.com']], ['hashkey', '1C6BFF', 'HK', ['hashkey exchange', 'hashkey global'], ['hashkey.com', 'hashkey.com.hk', 'hashkeyexchange.com']],
  ['coinone', '0062DF', 'Coinone', ['코인원'], ['coinone.co.kr']], ['korbit', '0C6EFF', 'Korbit', ['코빗'], ['korbit.co.kr']], ['zaif', '1B75BC', 'Zaif', [], ['zaif.jp']],
  ['btse', '1F2937', 'BTSE', [], ['btse.com']], ['coinhako', '0068FF', 'Hako', [], ['coinhako.com']], ['independentreserve', '0A2540', 'IR', ['independent reserve'], ['independentreserve.com']],
  ['coinspot', '0B67B2', 'CoinSpot', [], ['coinspot.com.au']], ['swyftx', '1B6EF3', 'Swyftx', [], ['swyftx.com']], ['bitbank', '1E3A8A', 'bitbank', [], ['bitbank.cc']],
  // Crypto wallets
  ['trustwallet', '0500FF', 'Trust', ['trust wallet'], ['trustwallet.com']], ['phantom', 'AB9FF2', 'Ph', ['phantom wallet'], ['phantom.app', 'phantom.com']], ['exodus', '8A5CF5', 'EXO', ['exodus wallet'], ['exodus.com', 'exodus.io']],
  ['rainbow', '001E59', 'RB', ['rainbow wallet'], ['rainbow.me']], ['safepal', '1F6BFF', 'SP', [], ['safepal.com', 'safepal.io']], ['tokenpocket', '2980FE', 'TP', ['token pocket'], ['tokenpocket.pro']],
  ['imtoken', '098DE6', 'imT', [], ['token.im', 'imtoken.com']], ['argent', 'FF875B', 'Arg', ['argent wallet'], ['argent.xyz']], ['zerion', '2962EF', 'Zer', [], ['zerion.io']],
  ['rabby', '8697FF', 'Rabby', ['rabby wallet'], ['rabby.io']], ['keplr', '2C75FF', 'Keplr', [], ['keplr.app']], ['electrum', '3A70B0', 'Elec', ['electrum wallet'], ['electrum.org']],
  ['atomicwallet', '0072CE', 'Atomic', ['atomic wallet'], ['atomicwallet.io']], ['bitgo', '0A70E0', 'BitGo', [], ['bitgo.com']], ['fireblocks', '0A0F1F', 'FB', [], ['fireblocks.com']],
  ['solflare', 'FFEF46', 'Sol', ['solflare wallet'], ['solflare.com']], ['tronlink', '0F1218', 'TL', [], ['tronlink.org']], ['unisat', 'F7931A', 'UniSat', [], ['unisat.io']],
  ['sparrow', '1A1A1A', 'Sparrow', ['sparrow wallet'], ['sparrowwallet.com']], ['myetherwallet', '05C0A5', 'MEW', ['my ether wallet', 'mew wallet'], ['myetherwallet.com', 'myetherwallet.com']],
  ['uniswap', 'FF007A', 'Uni', [], ['uniswap.org', 'app.uniswap.org']], ['pancakeswap', '1FC7D4', 'Cake', [], ['pancakeswap.finance']], ['bluewallet', '0C2550', 'Blue', ['blue wallet'], ['bluewallet.io']],
  ['muun', '5A2A82', 'Muun', ['muun wallet'], ['muun.com']], ['phoenixwallet', '2B3A67', 'Phnx', ['phoenix wallet'], ['phoenix.acinq.co']], ['walletofsatoshi', 'FFC20E', 'WoS', ['wallet of satoshi'], ['walletofsatoshi.com']],
  ['guarda', '2F72F2', 'Guarda', ['guarda wallet'], ['guarda.com']], ['coinomi', '0B3B6F', 'Coinomi', [], ['coinomi.com']], ['edgewallet', '0D2D4A', 'Edge', ['edge wallet'], ['edge.app']],
  ['ellipal', '0A3A5A', 'Ellipal', [], ['ellipal.com']], ['keystone', '0A5C5C', 'Key', ['keystone wallet'], ['keyst.one']], ['tangem', '1A1A1A', 'Tangem', [], ['tangem.com']],
  ['mathwallet', '1A1A1A', 'Math', ['math wallet'], ['mathwallet.org']], ['zengo', '0E0E10', 'Zengo', [], ['zengo.com']], ['ronin', '1273EA', 'Ronin', ['ronin wallet'], ['roninchain.com', 'wallet.roninchain.com']],
  ['tonkeeper', '45AEF5', 'Ton', [], ['tonkeeper.com']], ['backpack', 'E33E3F', 'BP', ['backpack wallet'], ['backpack.app', 'backpack.exchange']], ['coinbasewallet', '0052FF', 'CBW', ['coinbase wallet'], ['wallet.coinbase.com']],
  ['okxwallet', '000000', 'OKX', ['okx wallet'], ['web3.okx.com']],
  // Big names Simple Icons has dropped
  ['microsoft', '5E5E5E', 'MS', ['outlook', 'office 365', 'office', 'hotmail', 'microsoft account'], ['microsoft.com', 'live.com', 'outlook.com', 'office.com', 'microsoftonline.com', 'hotmail.com']],
  ['amazon', 'FF9900', 'a', ['amazon prime', 'amazon.com'], ['amazon.com', 'amazon.co.uk', 'amazon.de', 'amazon.co.jp', 'amazon.ca', 'amazon.cn', 'amazon.fr', 'amazon.it', 'amazon.es', 'amazon.in', 'amazon.com.au']],
  ['aws', 'FF9900', 'aws', ['amazon web services'], ['aws.amazon.com', 'amazonaws.com']], ['linkedin', '0A66C2', 'in', [], ['linkedin.com']], ['slack', '4A154B', 'S', [], ['slack.com']],
  ['skype', '00AFF0', 'S', [], ['skype.com']], ['disneyplus', '113CCF', 'D+', ['disney+', 'disney plus'], ['disneyplus.com', 'disney.com']], ['hulu', '1CE783', 'hulu', [], ['hulu.com']],
  ['primevideo', '00A8E1', 'prime', ['prime video', 'amazon prime video'], ['primevideo.com']], ['canva', '00C4CC', 'Canva', [], ['canva.com']], ['adobe', 'FA0F00', 'Adobe', ['adobe id', 'creative cloud'], ['adobe.com']],
  ['heroku', '430098', 'H', [], ['heroku.com']], ['openai', '10A37F', 'OpenAI', ['chatgpt'], ['openai.com', 'chatgpt.com']], ['kraken', '5741D9', 'K', [], ['kraken.com']],
  ['bybit', 'F7A600', 'Bybit', [], ['bybit.com']], ['metamask', 'F6851B', 'MM', [], ['metamask.io']], ['ledger', '111111', 'L', ['ledger live'], ['ledger.com']],
  ['wechatpay', '07C160', 'Pay', ['wechat pay', '微信支付'], ['pay.weixin.qq.com']], ['yahoo', '6001D2', 'Y!', ['yahoo mail'], ['yahoo.com', 'ymail.com', 'yahoo.co.jp']],
  ['nintendo', 'E60012', 'N', ['nintendo switch', 'nintendo account'], ['nintendo.com']], ['xbox', '107C10', 'Xbox', [], ['xbox.com']], ['walmart', '0071CE', 'W', [], ['walmart.com']],
  // United States
  ['citi', '056DAE', 'citi', ['citibank', 'citi bank', 'citigroup'], ['citi.com', 'citibank.com', 'citibankonline.com', 'citibank.com.hk']],
  ['capitalone', 'D03027', 'C1', ['capital one'], ['capitalone.com']], ['schwab', '00A0DF', 'CS', ['charles schwab', 'schwab bank'], ['schwab.com']],
  ['fidelity', '368727', 'F', ['fidelity investments'], ['fidelity.com']], ['vanguard', '96151D', 'V', [], ['vanguard.com']], ['usbank', '0C2074', 'USB', ['us bank', 'u.s. bank', 'u s bank'], ['usbank.com']],
  ['pnc', 'F58025', 'PNC', ['pnc bank'], ['pnc.com']], ['truist', '2E1A47', 'T', [], ['truist.com']], ['tdbank', '34A853', 'TD', ['td bank', 'td ameritrade'], ['td.com', 'tdbank.com', 'tdameritrade.com']],
  ['citizens', '007A4D', 'CZ', ['citizens bank', 'citizens financial'], ['citizensbank.com', 'citizens.com']], ['ally', '650360', 'ally', ['ally bank'], ['ally.com']], ['sofi', '00A6D6', 'SoFi', [], ['sofi.com']],
  ['navyfederal', '003B6F', 'NF', ['navy federal credit union', 'nfcu'], ['navyfederal.org']], ['usaa', '00385F', 'USAA', [], ['usaa.com']], ['etrade', '6633CC', 'E*', ['e*trade', 'e trade'], ['etrade.com']],
  ['morganstanley', '002B51', 'MS', ['morgan stanley'], ['morganstanley.com']], ['interactivebrokers', 'D81222', 'IB', ['interactive brokers', 'ibkr'], ['interactivebrokers.com', 'ibkr.com']],
  ['fifththird', '00754A', '53', ['fifth third', 'fifth third bank'], ['53.com']], ['regions', '5B8C00', 'R', ['regions bank'], ['regions.com']], ['keybank', 'C8102E', 'KEY', [], ['key.com']],
  // Taiwan
  ['ctbc', '007A3D', 'CTBC', ['中國信託', '中国信托', 'ctbc bank'], ['ctbcbank.com']], ['cathaybk', '007A33', 'Cathay', ['國泰世華', '国泰世华', 'cathay united bank', 'cathay bank'], ['cathaybk.com.tw', 'cathaybk.com']],
  ['esun', '008D5A', 'E.SUN', ['玉山', '玉山銀行', 'esun bank'], ['esunbank.com', 'esunbank.com.tw']], ['taishin', 'E60012', 'TSB', ['台新', '台新銀行', 'taishin bank', 'richart'], ['taishinbank.com.tw', 'richart.tw']],
  ['fubon', '0073B7', 'Fubon', ['富邦', '台北富邦', 'taipei fubon'], ['fubon.com', 'fubonbank.com.tw']], ['megabank', '0069B3', 'MEGA', ['兆豐', '兆丰', 'mega bank', 'mega international commercial bank'], ['megabank.com.tw']],
  ['firstbank', '1C4FA0', '1st', ['第一銀行', 'first bank', 'first commercial bank'], ['firstbank.com.tw']], ['huanan', '0A4A8A', 'HNCB', ['華南銀行', '华南银行', 'hua nan bank'], ['hncb.com.tw']],
  ['changhwa', 'D6001C', 'CHB', ['彰化銀行', 'chang hwa bank'], ['bankchb.com']], ['bankoftaiwan', '006A4E', 'BOT', ['台灣銀行', '臺灣銀行', 'bank of taiwan'], ['bot.com.tw']],
  ['tcb', '0067B1', 'TCB', ['合作金庫', 'taiwan cooperative bank'], ['tcb-bank.com.tw']], ['sinopac', 'E60012', 'SinoPac', ['永豐銀行', '永丰银行', 'sinopac bank'], ['sinopac.com', 'bank.sinopac.com']],
  ['chunghwapost', '00A651', 'Post', ['中華郵政', '中华邮政', 'chunghwa post'], ['post.gov.tw']], ['landbank', '00843D', 'LBOT', ['土地銀行', 'land bank of taiwan'], ['landbank.com.tw']],
  ['linebank', '06C755', 'LINE', ['line bank'], ['linebank.com.tw']], ['kgi', 'C8102E', 'KGI', ['凱基銀行', '凯基银行', 'kgi bank'], ['kgibank.com']],
  // Mainland China
  ['icbc', 'C7000B', 'ICBC', ['工商銀行', '工商银行', '工行', 'industrial and commercial bank of china'], ['icbc.com.cn', 'icbc.com', 'icbc-asia.com']],
  ['ccb', '0C4DA2', 'CCB', ['建設銀行', '建设银行', '建行', 'china construction bank'], ['ccb.com', 'ccb.com.cn']], ['abc', '009A57', 'ABC', ['農業銀行', '农业银行', '农行', 'agricultural bank of china'], ['abchina.com', 'abchina.com.cn']],
  ['bankofchina', 'A6192E', 'BOC', ['中國銀行', '中国银行', '中行', 'bank of china', 'boc hk', '中銀香港', '中银香港'], ['boc.cn', 'bankofchina.com', 'bochk.com']], ['bankcomm', '0A4C9A', 'BoCom', ['交通銀行', '交通银行', '交行', 'bank of communications'], ['bankcomm.com', 'bankcomm.com.cn']],
  ['cmb', 'C8161D', 'CMB', ['招商銀行', '招商银行', '招行', 'china merchants bank'], ['cmbchina.com', 'cmbwinglungbank.com']], ['pingan', 'F2711C', 'PA', ['平安銀行', '平安银行', '中国平安', 'ping an', 'ping an bank'], ['pingan.com', 'bank.pingan.com', 'pingan.com.cn']],
  ['citic', 'C8161D', 'CITIC', ['中信銀行', '中信银行', 'china citic bank'], ['citicbank.com', 'citic.com']], ['psbc', '00843D', 'PSBC', ['郵儲銀行', '邮储银行', '邮政储蓄', 'postal savings bank of china'], ['psbc.com']],
  ['cib', '00539B', 'CIB', ['興業銀行', '兴业银行', 'industrial bank'], ['cib.com.cn']], ['spdb', '0B4E9D', 'SPDB', ['浦發銀行', '浦发银行', 'shanghai pudong development bank'], ['spdb.com.cn']],
  ['cmbc', '00A0E9', 'CMBC', ['民生銀行', '民生银行', 'china minsheng bank'], ['cmbc.com.cn']], ['cebbank', '7B2C7C', 'CEB', ['光大銀行', '光大银行', 'china everbright bank'], ['cebbank.com']],
  ['hxb', 'E60012', 'HXB', ['華夏銀行', '华夏银行', 'huaxia bank'], ['hxb.com.cn']], ['unionpay', '01798A', 'UP', ['銀聯', '银联', 'union pay'], ['unionpay.com', 'unionpayintl.com']],
  // Hong Kong
  ['hangseng', '008550', 'HS', ['恒生', '恒生銀行', '恒生银行', 'hang seng bank'], ['hangseng.com']], ['standardchartered', '0473EA', 'SC', ['渣打', '渣打銀行', '渣打银行', 'standard chartered'], ['sc.com', 'standardchartered.com', 'standardchartered.com.hk']],
  ['bea', 'C8102E', 'BEA', ['東亞銀行', '东亚银行', 'bank of east asia'], ['hkbea.com', 'hkbea-cyberbanking.com']], ['dbs', 'E4002B', 'DBS', ['星展', '星展銀行', 'dbs bank', 'posb'], ['dbs.com', 'dbs.com.hk', 'posb.com.sg']],
  ['zabank', '00C389', 'ZA', ['za bank', '眾安銀行', '众安银行'], ['za.group', 'zabank.hk']], ['mox', '111111', 'Mox', ['mox bank'], ['mox.com']], ['welab', 'FF5A36', 'WeLab', ['welab bank', '匯立銀行'], ['welab.bank', 'welabbank.com']],
  ['livi', '00BFA5', 'livi', ['livi bank'], ['livibank.com']], ['airstar', '5B2EFF', 'Air', ['airstar bank', '天星銀行'], ['airstarbank.com']], ['fusion', '0070C0', 'Fusion', ['fusion bank'], ['fusionbank.com']],
  ['ocbc', 'E60012', 'OCBC', ['華僑銀行', 'ocbc bank', 'ocbc wing hang'], ['ocbc.com', 'ocbcwhhk.com']], ['uob', '0B3C8E', 'UOB', ['大華銀行', 'united overseas bank'], ['uob.com.sg', 'uobgroup.com']],
  ['octopus', 'F58220', 'Oct', ['八達通', '八达通', 'octopus card'], ['octopus.com.hk']], ['payme', 'DB0011', 'PayMe', [], ['payme.hsbc.com.hk']],
]

// Short marks that are also ordinary words or names: matched by domain only, never by name.
const TOO_GENERIC = new Set(['max', 'edge', 'gate', 'blue', 'rainbow', 'backpack', 'trust', 'ronin', 'sparrow', 'ms', 'in', 'a', 'post', 'air', 'oct', 'key', 'abc', 'mega', 'fusion', 'cib', 'regions', 'ally'])
const titleOf = (id, extra, mark) => norm(mark) === norm(id) && mark.length > 2 ? mark : (extra.find(e => norm(e) === norm(id) && /^[A-Za-z][A-Za-z .+*-]*$/.test(e)) || id).replace(/(^|\s)\w/g, c => c.toUpperCase())
const slugs = new Set(); const found = [], missing = []
const res = join(root, 'android/app/src/main/res/drawable-nodpi'), catalog = join(root, 'ios/PassVault/Assets.xcassets')
for (const f of readdirSync(res)) if (f.startsWith('brand_')) rmSync(join(res, f))
for (const f of readdirSync(catalog)) if (f.startsWith('brand_')) rmSync(join(catalog, f), { recursive: true })

const norm = s => s.toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')
const lum = hex => { const [r, g, b] = [0, 2, 4].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(c => c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4); return 0.2126 * r + 0.7152 * g + 0.0722 * b }
const SIZE = 192
const storeDir = join(root, 'assets/brand-icons')
mkdirSync(storeDir, { recursive: true })
// Writes one icon for both apps. An official app icon in assets/brand-icons wins over the generated fallback tile.
function writeIcon(id, fallbackSvg, fontOptions = {}) {
  const store = join(storeDir, `${id}.jpg`)
  const svg = existsSync(store)
    ? `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}"><clipPath id="c"><rect width="${SIZE}" height="${SIZE}" rx="44"/></clipPath><image width="${SIZE}" height="${SIZE}" clip-path="url(#c)" href="data:image/jpeg;base64,${readFileSync(store).toString('base64')}"/></svg>`
    : fallbackSvg
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: SIZE }, ...fontOptions }).render().asPng()
  writeFileSync(join(res, `brand_${id}.png`), png)
  const set = join(catalog, `brand_${id}.imageset`); mkdirSync(set, { recursive: true }); writeFileSync(join(set, `brand_${id}.png`), png)
  writeFileSync(join(set, 'Contents.json'), JSON.stringify({ images: [{ filename: `brand_${id}.png`, idiom: 'universal' }], info: { author: 'xcode', version: 1 } }, null, 2) + '\n')
}
for (const [slug, domains, extra = []] of BRANDS) {
  const key = 'si' + slug[0].toUpperCase() + slug.slice(1)
  const icon = icons[key]
  if (!icon || slugs.has(slug)) { if (!icon) missing.push(slug); continue }
  slugs.add(slug)
  // Brand-colored rounded tile with the logo in white (black on very light brand colors) so it stays readable in light and dark themes.
  const glyph = lum(icon.hex) > 0.6 ? '#000000' : '#FFFFFF'
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}"><rect width="${SIZE}" height="${SIZE}" rx="44" fill="#${icon.hex}"/><g transform="translate(48 48) scale(4)"><path fill="${glyph}" d="${icon.path}"/></g></svg>`
  const id = slug.replace(/[^a-z0-9]/g, '_')
  writeIcon(id, svg)
  found.push({ id, terms: [icon.title, ...extra], title: icon.title, names: [...new Set([icon.title, slug, ...extra].map(norm).filter(Boolean))], domains })
}

for (const [id0, hex, mark, extra, domains] of MONOGRAMS) {
  const id = id0.replace(/[^a-z0-9]/g, '_'); if (slugs.has(id)) continue; slugs.add(id)
  const size = mark.length <= 2 ? 84 : mark.length === 3 ? 64 : mark.length === 4 ? 52 : 42
  const glyph = lum(hex) > 0.6 ? '#000000' : '#FFFFFF'
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}"><rect width="${SIZE}" height="${SIZE}" rx="44" fill="#${hex}"/><text x="96" y="${96 + size * 0.35}" text-anchor="middle" font-family="Helvetica Neue, Helvetica, Arial" font-weight="700" font-size="${size}" fill="${glyph}">${mark.replace(/&/g, '&amp;')}</text></svg>`
  writeIcon(id, svg, { font: { loadSystemFonts: true, defaultFontFamily: 'Helvetica' } })
  found.push({ id, terms: [titleOf(id0, extra, mark), ...extra], title: titleOf(id0, extra, mark), names: [...new Set([...(mark.length >= 3 ? [mark] : []), ...(id0.length >= 4 ? [id0] : []), ...extra].map(norm).filter(n => n && !TOO_GENERIC.has(n)))], domains })
}

// --- Optional: fetch official app icons from the App Store -----------------------------------------------------------------------
// `node scripts/generate-brand-icons.mjs --fetch` downloads any brand's icon that isn't in assets/brand-icons yet, then re-run without it.
if (process.argv.includes('--fetch')) {
  const sourcesFile = join(storeDir, 'sources.json')
  const sources = existsSync(sourcesFile) ? JSON.parse(readFileSync(sourcesFile, 'utf8')) : {}
  const region = domains => { const d = domains.join(' '); return /\.tw\b/.test(d) ? 'tw' : /\.hk\b|hangseng|bochk|hkbea|za\.group/.test(d) ? 'hk' : /\.cn\b|icbc\.com$|ccb\.com$|abchina|boc\.cn|cmbchina|pingan|citicbank|psbc|bankcomm|qq\.com|baidu|weibo|bilibili|taobao|alipay|zhihu|douban|weixin/.test(d) ? 'cn' : /\.jp\b|coincheck|bitflyer|zaif/.test(d) ? 'jp' : /\.kr\b|upbit|bithumb/.test(d) ? 'kr' : /\.co\.uk\b|monzo|barclays/.test(d) ? 'gb' : 'us' }
  const pause = ms => new Promise(r => setTimeout(r, ms))
  const search = async (term, country) => {
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const r = await fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(term)}&country=${country}&entity=software&limit=8`)
        if (r.ok) return (await r.json()).results || []
      } catch { /* network hiccup: retry below */ }
      await pause(20000 * (attempt + 1))
    }
    return []
  }
  for (const b of found) {
    if (sources[b.id] || existsSync(join(storeDir, `${b.id}.jpg`))) continue
    const reg = region(b.domains), cjk = b.terms.find(t => /[\u3400-\u9fff\uac00-\ud7af]/.test(t))
    const attempts = [[b.terms[0], reg], ...(cjk ? [[cjk, reg]] : []), ...(reg !== 'us' ? [[b.terms[0], 'us']] : [])]
    let hit = null
    for (const [term, country] of attempts) {
      const n = norm(term); if (n.length < 3 && !/[\u3400-\u9fff]/.test(n)) continue
      const results = await search(term, country); await pause(3500)
      hit = results.find(r => norm(r.trackName || '').includes(n) || norm(r.sellerName || '').includes(n))
      if (hit) { hit.term = term; hit.country = country; break }
    }
    if (!hit) { console.log(`no store icon: ${b.id}`); sources[b.id] = null; writeFileSync(sourcesFile, JSON.stringify(sources, null, 1)); continue }
    let data = null
    for (let attempt = 0; attempt < 4 && !data; attempt++) {
      try {
        const img = await fetch(hit.artworkUrl512 || hit.artworkUrl100.replace('100x100bb', '512x512bb'))
        if (img.ok) data = Buffer.from(await img.arrayBuffer())
      } catch { /* network hiccup: retry */ }
      if (!data) await pause(5000 * (attempt + 1))
    }
    if (!data) { console.log(`download failed: ${b.id}`); continue }
    writeFileSync(join(storeDir, `${b.id}.jpg`), data)
    sources[b.id] = { app: hit.trackName, seller: hit.sellerName, appStoreId: hit.trackId, country: hit.country, searched: hit.term }
    writeFileSync(sourcesFile, JSON.stringify(sources, null, 1))
    console.log(`${b.id} <- ${hit.trackName} (${hit.sellerName}, ${hit.country})`)
  }
  console.log('Fetch done. Re-run without --fetch to rebuild the icons, and review them.')
  process.exit(0)
}

const q = s => JSON.stringify(s)
const kt = `package app.passvault

// GENERATED by scripts/generate-brand-icons.mjs. Do not edit by hand.
/** A well-known service: normalized names people type and domains it lives on (subdomains match too). */
class Brand(val id: String, val title: String, val names: Set<String>, val domains: List<String>, val drawable: Int)

internal val brands: List<Brand> = listOf(
${found.map(b => `    Brand(${q(b.id)}, ${q(b.title)}, setOf(${b.names.map(q).join(', ')}), listOf(${b.domains.map(q).join(', ')}), R.drawable.brand_${b.id}),`).join('\n')}
)
`
writeFileSync(join(root, 'android/app/src/main/java/app/passvault/BrandData.kt'), kt)
const sw = `// GENERATED by scripts/generate-brand-icons.mjs. Do not edit by hand.
import Foundation

/// A well-known service: normalized names people type and domains it lives on (subdomains match too). The image is the asset "brand_<id>".
public struct Brand: Sendable {
    public let id: String, title: String, names: Set<String>, domains: [String]
    public var assetName: String { "brand_" + id }
}

let allBrands: [Brand] = [
${found.map(b => `    Brand(id: ${q(b.id)}, title: ${q(b.title)}, names: [${b.names.map(q).join(', ')}], domains: [${b.domains.map(q).join(', ')}]),`).join('\n')}
]
`
writeFileSync(join(root, 'ios/Sources/VaultCore/BrandData.swift'), sw)
console.log(`${found.length} brand icons written.`, missing.length ? `Not in Simple Icons, skipped: ${missing.join(', ')}` : '')
