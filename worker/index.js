require('dotenv/config')
const fs = require('fs')
const path = require('path')
const Promise = require('bluebird')
const Web3 = require('web3')
const redis = require('redis')
const BigNumber = require('bignumber.js')
const express = require('express')

let web3
let chartContract
let redisClient
let ethAccounts

async function main() {
    //
    // Initialize web3
    //

    // web3 = new Web3(process.env.ETH_NODE_HOST)

    // This idiotic workaround is due to the poor architecture and maintainership of web3.js
    // See https://github.com/ethereum/web3.js/issues/2786
    const provider = new Web3.providers.HttpProvider(process.env.ETH_NODE_HOST)
    web3 = new Web3('http://')
    web3.setProvider(provider)

    ethAccounts = await web3.eth.getAccounts() // we use this as a health check

    const chartContractJson = JSON.parse(fs.readFileSync(path.join(process.env.CONTRACT_JSON_ROOT, 'Chart.json'), 'utf8'))
    const currentNetwork = await web3.eth.net.getId()

    if (!chartContractJson.networks[currentNetwork] || !chartContractJson.networks[currentNetwork].address) {
        throw new Error(`Chart.json doesn't contain an entry for the current network ID (${currentNetwork}) ... are you sure you deployed the contract to this network?`)
    }

    chartContract = new web3.eth.Contract(chartContractJson.abi, chartContractJson.networks[currentNetwork].address)

    console.log('web3 initialized')


    //
    // Initialize redis
    //

    redisClient = redis.createClient({
        host: process.env.REDIS_HOST,
        port: process.env.REDIS_PORT,
    })
    redisClient = Promise.promisifyAll(redisClient, { suffix: 'Async' })

    await redisClient.onAsync('ready')
    console.log('redis initialized')

    startWorker()
    startHTTPServer()
}

const DECIMALS = new BigNumber(10).pow(18)

async function getSong(cid) {
    let { submittedInBlock, currentUpvotes, allTimeUpvotes } = await chartContract.methods.songs(cid).call()
    submittedInBlock = new BigNumber(submittedInBlock.toString())
    currentUpvotes   = new BigNumber(currentUpvotes.toString()).div(DECIMALS)
    allTimeUpvotes   = new BigNumber(allTimeUpvotes.toString()).div(DECIMALS)
    return { submittedInBlock, currentUpvotes, allTimeUpvotes }
}

async function getSongScore(song) {
    let blockNumber = await web3.eth.getBlockNumber()
    blockNumber = new BigNumber(blockNumber.toString())
    const delta = blockNumber.minus(song.submittedInBlock)
    return song.allTimeUpvotes.div( delta.times(0.2).plus(1) )
}

async function startWorker() {

    async function loop() {
        const events = await chartContract.getPastEvents('SongProposed', { fromBlock: 0, toBlock: 'latest' })
        const cids = events.map(e => e.returnValues.cid)

        for (let cid of cids) {
            const song = await getSong(cid)
            const score = await getSongScore(song)
            song.submittedInBlock = song.submittedInBlock.toString()
            song.currentUpvotes = song.currentUpvotes.toString()
            song.allTimeUpvotes = song.allTimeUpvotes.toString()
            await redisClient.zaddAsync('leaderboard', score.toString(), cid)
            await redisClient.hsetAsync('songs', cid, JSON.stringify(song))
        }

        setTimeout(loop, 1000)
    }

    loop()
}

function startHTTPServer() {
    const app = express()
    const port = process.env.PORT || 3000

    app.use(express.static('static'))

    app.get('/clear-redis', async (req, res) => {
        redisClient.del('leaderboard')
        redisClient.del('songs')
        res.json({})
    })

    app.get('/leaderboard', async (req, res) => {
        const { offset = 0, limit = 10 } = req.query
        const items = await redisClient.zrevrangeAsync('leaderboard', offset, offset + limit, 'WITHSCORES')
        const list = []
        for (let i = 0; i < items.length/2; i++) {
            const cid = items[i*2]
            const x = await redisClient.hgetAsync('songs', cid)
            const song = JSON.parse(x)
            list.push({ ...song, cid, score: items[i*2+1] })
        }

        res.json(list)
    })

    app.listen(port, () => console.log(`http server initialized (port ${port})`))
}

main()

