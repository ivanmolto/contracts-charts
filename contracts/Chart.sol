pragma solidity 0.5.0;

contract Chart
{
    uint constant DECIMALS = 18;
    PayoutCurve public payoutCurve;
    uint public proposalCost;
    uint public upvoteCost = 1 * (10 ** DECIMALS);

    constructor(PayoutCurve _payoutCurve, uint _proposalCost) public {
        payoutCurve = _payoutCurve;
        proposalCost = _proposalCost * (10 ** DECIMALS);
    }

    enum PayoutCurve {
        Linear,
        Reciprocal
    }

    struct Song {
        // Tracks the block when the song was initially submitted (to facilitate calculating a score that decays over time)
        uint submittedInBlock;
        // Tracks the number of tokenized votes not yet withdrawn from the song.  We use this to calculate withdrawable amounts.
        uint currentUpvotes;
        // Tracks the total number of tokenized votes this song has received.  We use this to rank songs.
        uint allTimeUpvotes;
        // Maps a user's address to their place in the "queue" of users who have upvoted this song.  Used to calculate withdrawable amounts.
        mapping(address => Upvote) upvotes;
    }

    struct Upvote {
        uint index; // 1-based index
        uint withdrawnAmount;
    }

    mapping(bytes32 => Song) public songs;
    mapping(address => uint) public balanceOf; // token balances
    mapping(address => bool) knownAddresses;

    //
    // Events
    //

    event SongProposed(address indexed proposer, bytes32 cid);
    event SongUpvoted(address indexed upvoter, bytes32 cid);

    //
    // Upvote mechanism
    //

    modifier maybeTokenGrant {
        if (knownAddresses[msg.sender] == false) {
            knownAddresses[msg.sender] = true;
            balanceOf[msg.sender] = 100 * (10 ** DECIMALS);
        }
        _;
    }

    function propose(bytes32 cid) maybeTokenGrant public {
        require(songs[cid].submittedInBlock == 0, "already proposed");
        require(balanceOf[msg.sender] >= proposalCost, "not enough tokens to propose");

        Song storage song = songs[cid];
        song.submittedInBlock = block.number;

        balanceOf[msg.sender] -= proposalCost;
        song.currentUpvotes += proposalCost;
        song.allTimeUpvotes += proposalCost;
        song.upvotes[msg.sender].index = 1;

        emit SongProposed(msg.sender, cid);
    }

    function upvote(bytes32 cid) maybeTokenGrant public {
        require(balanceOf[msg.sender] >= upvoteCost, "not enough tokens to upvote");
        balanceOf[msg.sender] -= upvoteCost;

        Song storage song = songs[cid];
        require(song.upvotes[msg.sender].index == 0, "you have already upvoted this song");

        song.currentUpvotes += upvoteCost;
        song.allTimeUpvotes += upvoteCost;
        song.upvotes[msg.sender].index = ((song.currentUpvotes - proposalCost) / (10 ** DECIMALS)) + 1;

        emit SongUpvoted(msg.sender, cid);
    }

    function withdraw(bytes32 cid) public {
        Song storage song = songs[cid];

        require(song.upvotes[msg.sender].index > 0, "you don't have any tokens stored in this song");

        uint totalWithdrawable = getWithdrawableAmount(msg.sender, cid);
        uint alreadyWithdrawn = song.upvotes[msg.sender].withdrawnAmount;
        uint amountToWithdraw = totalWithdrawable - alreadyWithdrawn;

        require(song.currentUpvotes >= amountToWithdraw, "calculated withdrawal amount is greater than remaining token supply for this song");

        song.upvotes[msg.sender].withdrawnAmount = totalWithdrawable;

        song.currentUpvotes -= amountToWithdraw;
        balanceOf[msg.sender] += amountToWithdraw;
    }

    //
    // Getters
    //

    function getWithdrawableAmount(address user, bytes32 cid) public view returns (uint) {
        Song storage song = songs[cid];
        uint i = song.upvotes[user].index;
        uint t = song.allTimeUpvotes;

        if (payoutCurve == PayoutCurve.Linear) {
            return (((uint(-2) * i) - 1) / t) + 2;
        } else if (payoutCurve == PayoutCurve.Reciprocal) {
            revert("not done yet");
        } else {
            revert("unknown payout curve");
        }
    }

    function getCurrentUpvotes(bytes32 cid) public view returns (uint) {
        return songs[cid].currentUpvotes;
    }

    function getAllTimeUpvotes(bytes32 cid) public view returns (uint) {
        return songs[cid].allTimeUpvotes;
    }

    function getSongScore(bytes32 cid) public view returns (uint) {
        Song storage song = songs[cid];
        require(song.submittedInBlock > 0, "song doesn't exist");

        uint delta = block.number - song.submittedInBlock;
        // @@TODO: this way of calculating decay is completely arbitrary
        return song.allTimeUpvotes / (delta + 1);
    }
}

