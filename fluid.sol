// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80);
    function decimals() external view returns (uint8);
}

contract FLDTokenManager {
    using SafeERC20 for IERC20;

    IERC20 public token;

    // ----- Multisig -----
    address[3] public signers;
    mapping(bytes32 => mapping(address => bool)) public approvals;
    mapping(bytes32 => bool) public executed;

    modifier onlySigner() {
        require(msg.sender == signers[0] || msg.sender == signers[1] || msg.sender == signers[2], "Not signer");
        _;
    }

    constructor(address _token, address[3] memory _signers) {
        require(_token != address(0), "Invalid token");
        token = IERC20(_token);
        for (uint i = 0; i < 3; i++) require(_signers[i] != address(0), "Invalid signer");
        signers = _signers;
    }

    function _submitAndExecute(address to, bytes memory data) internal {
        bytes32 txId = keccak256(abi.encodePacked(to, data, block.number));
        approvals[txId][msg.sender] = true;

        uint count = 0;
        for (uint i = 0; i < 3; i++) {
            if (approvals[txId][signers[i]]) count++;
        }

        if (count >= 3 && !executed[txId]) {
            executed[txId] = true;
            (bool success,) = to.call(data);
            require(success, "Execution failed");
        }
    }

    // ----- Supply & Allocation -----
    uint256 public constant MAX_SUPPLY = 10_000_000 * 1e18;

    uint256 public presaleSold;
    uint256 public presaleCap = 4_000_000 * 1e18;

    uint256 public airdropCap = 3_000_000 * 1e18;
    uint256 public distributedAirdrops;

    uint256 public teamAllocated;
    uint256 public foundationAllocated;
    uint256 public liquidityAllocated;

    // ----- Price / Oracles -----
    uint256 public fluidPriceUSDT6 = 1e6;
    mapping(address => AggregatorV3Interface) public priceFeeds;
    AggregatorV3Interface public nativePriceFeed;

    // ----- Presale -----
    bool public presaleActive;

    function startPresale() external onlySigner {
        bytes memory data = abi.encodeWithSignature("startPresaleInternal()");
        _submitAndExecute(address(this), data);
    }
    function startPresaleInternal() external {
        require(msg.sender == address(this), "Internal only");
        presaleActive = true;
    }

    function stopPresale() external onlySigner {
        bytes memory data = abi.encodeWithSignature("stopPresaleInternal()");
        _submitAndExecute(address(this), data);
    }
    function stopPresaleInternal() external {
        require(msg.sender == address(this), "Internal only");
        presaleActive = false;
    }

    function buyWithERC20(address payToken, uint256 payAmount, uint256 minOut, address buyer) external {
        require(presaleActive, "Inactive presale");
        require(priceFeeds[payToken] != AggregatorV3Interface(address(0)), "No feed");

        uint256 fluidAmount = _calcFromERC20(payToken, payAmount);
        require(fluidAmount >= minOut && presaleSold + fluidAmount <= presaleCap, "Invalid amount");

        IERC20(payToken).safeTransferFrom(buyer, address(this), payAmount);
        presaleSold += fluidAmount;
        liquidityAllocated = MAX_SUPPLY - presaleSold - distributedAirdrops - teamAllocated - foundationAllocated;

        token.safeTransfer(buyer, fluidAmount);

        // Allocate proportional airdrop
        uint256 airdropAlloc = (fluidAmount * airdropCap) / presaleCap;
        _allocateAirdrop(buyer, airdropAlloc);
    }

    function buyWithNative(address buyer, uint256 minOut) external payable {
        require(presaleActive, "Inactive presale");
        uint256 fluidAmount = _calcFromNative(msg.value);
        require(fluidAmount >= minOut && presaleSold + fluidAmount <= presaleCap, "Invalid amount");

        presaleSold += fluidAmount;
        liquidityAllocated = MAX_SUPPLY - presaleSold - distributedAirdrops - teamAllocated - foundationAllocated;

        token.safeTransfer(buyer, fluidAmount);

        // Allocate proportional airdrop
        uint256 airdropAlloc = (fluidAmount * airdropCap) / presaleCap;
        _allocateAirdrop(buyer, airdropAlloc);
    }

    function _calcFromERC20(address payToken, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface feed = priceFeeds[payToken];
        (, int256 price, , , ) = feed.latestRoundData();
        require(price > 0, "Invalid price");
        uint8 dec = feed.decimals();
        return (amount * uint256(price) * 1e6) / (10 ** dec) / fluidPriceUSDT6;
    }

    function _calcFromNative(uint256 amount) internal view returns (uint256) {
        (, int256 price, , , ) = nativePriceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return (amount * uint256(price) * 1e6) / (10 ** nativePriceFeed.decimals()) / fluidPriceUSDT6;
    }

    // ----- Airdrops -----
    struct Allocation { uint256 amount; bool claimed; uint256 expiry; }
    mapping(address => Allocation) public allocations;
    uint256 public constant EXPIRY_PERIOD = 180 days;
    bool public airdropActive;
    uint256 public airdropEnd;

    function startAirdrop(uint256 duration) external onlySigner {
        bytes memory data = abi.encodeWithSignature("startAirdropInternal(uint256)", duration);
        _submitAndExecute(address(this), data);
    }
    function startAirdropInternal(uint256 duration) external {
        require(msg.sender == address(this), "Internal only");
        airdropActive = true;
        airdropEnd = block.timestamp + duration;
    }

    function stopAirdrop() external onlySigner {
        bytes memory data = abi.encodeWithSignature("stopAirdropInternal()");
        _submitAndExecute(address(this), data);
    }
    function stopAirdropInternal() external {
        require(msg.sender == address(this), "Internal only");
        airdropActive = false;
    }

    function _allocateAirdrop(address user, uint256 amount) internal {
        require(distributedAirdrops + amount <= airdropCap, "Airdrop cap exceeded");
        Allocation storage a = allocations[user];
        if (a.amount == 0) a.expiry = block.timestamp + EXPIRY_PERIOD;
        a.amount += amount;
        distributedAirdrops += amount;
        liquidityAllocated = MAX_SUPPLY - presaleSold - distributedAirdrops - teamAllocated - foundationAllocated;
    }

    function claimAirdrop() external {
        Allocation storage a = allocations[msg.sender];
        require(a.amount > 0 && !a.claimed && block.timestamp <= a.expiry, "Cannot claim");
        a.claimed = true;
        token.safeTransfer(msg.sender, a.amount);
    }

    function recoverExpired(address user) external onlySigner {
        bytes memory data = abi.encodeWithSignature("recoverExpiredInternal(address)", user);
        _submitAndExecute(address(this), data);
    }
    function recoverExpiredInternal(address user) external {
        require(msg.sender == address(this), "Internal only");
        Allocation storage a = allocations[user];
        require(a.amount > 0 && !a.claimed && block.timestamp > a.expiry, "Nothing expired");

        distributedAirdrops -= a.amount;
        a.amount = 0;
        a.claimed = false;
        a.expiry = 0;

        liquidityAllocated = MAX_SUPPLY - presaleSold - distributedAirdrops - teamAllocated - foundationAllocated;
    }

    function moveUnclaimedTo(address wallet) external onlySigner {
        bytes memory data = abi.encodeWithSignature("moveUnclaimedInternal(address)", wallet);
        _submitAndExecute(address(this), data);
    }
    function moveUnclaimedInternal(address wallet) external {
        require(msg.sender == address(this), "Internal only");
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(wallet, balance);
    }

    // ----- Liquidity / CEX Allocation -----
    mapping(address => uint256) public cexAllocation;
    mapping(address => bool) public cexClaimed;

    function allocateCEX(address cex, uint256 amount) external onlySigner {
        require(cex != address(0), "Invalid CEX");
        require(amount > 0 && cexAllocation[cex] == 0, "Already allocated");
        require(liquidityAllocated >= amount, "Insufficient liquidity");

        cexAllocation[cex] = amount;
        liquidityAllocated -= amount;
    }

    function claimCEX() external {
        uint256 amount = cexAllocation[msg.sender];
        require(amount > 0 && !cexClaimed[msg.sender], "Cannot claim");
        cexClaimed[msg.sender] = true;
        token.safeTransfer(msg.sender, amount);
    }

    // ----- Team / Foundation Vesting -----
    uint256 public constant VESTING_DURATION = 10 * 365 days;
    uint256 public constant CLAIM_INTERVAL = 182 days;

    struct Vesting { uint256 totalAllocated; uint256 released; uint256 startTime; uint8 lastReleasePeriod; }
    Vesting public teamVesting;
    Vesting public foundationVesting;
    address public teamWallet;
    address public foundationWallet;

    function initVesting(address _team, address _foundation, uint256 teamAmount, uint256 foundationAmount) external onlySigner {
        bytes memory data = abi.encodeWithSignature("initVestingInternal(address,address,uint256,uint256)", _team, _foundation, teamAmount, foundationAmount);
        _submitAndExecute(address(this), data);
    }
    function initVestingInternal(address _team, address _foundation, uint256 teamAmount, uint256 foundationAmount) external {
        require(msg.sender == address(this), "Internal only");
        teamWallet = _team;
        foundationWallet = _foundation;
        teamVesting.totalAllocated = teamAmount;
        teamVesting.startTime = block.timestamp;
        teamAllocated = teamAmount;
        foundationVesting.totalAllocated = foundationAmount;
        foundationVesting.startTime = block.timestamp;
        foundationAllocated = foundationAmount;

        liquidityAllocated = MAX_SUPPLY - presaleSold - distributedAirdrops - teamAllocated - foundationAllocated;
    }

    function releaseVesting() public {
        _release(teamVesting, teamWallet);
        _release(foundationVesting, foundationWallet);
    }

    function _currentPeriod(uint256 startTime) internal view returns (uint8) {
        uint256 elapsed = block.timestamp > startTime ? block.timestamp - startTime : 0;
        return uint8(elapsed / CLAIM_INTERVAL);
    }

    function _release(Vesting storage v, address wallet) internal {
        uint8 current = _currentPeriod(v.startTime);
        if (current > v.lastReleasePeriod && v.released < v.totalAllocated) {
            uint256 vested = (v.totalAllocated * (current + 1) * CLAIM_INTERVAL) / VESTING_DURATION;
            uint256 releasable = vested - v.released;
            if (releasable > 0) {
                v.released += releasable;
                v.lastReleasePeriod = current;
                token.safeTransfer(wallet, releasable);
            }
        }
    }
}
