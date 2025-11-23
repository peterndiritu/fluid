
// File: FluidToken.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
FluidToken (FLUID)

- ERC20 token, total supply 10,000,000
- Presale, airdrops, team, foundation & liquidity allocations
- 10-year vesting for airdrops
- Owner can pause or modify airdrops
- Burn and cross-chain mint support to maintain 10M total supply
- CEX liquidity allocation post-deployment
*/

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/Ownable.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

contract FluidToken is ERC20, Ownable {
    using SafeERC20 for IERC20;

    // ----- Supply -----
    uint256 public constant MAX_SUPPLY = 10_000_000 * 1e18;
    uint256 public constant PRESALE_SUPPLY = 4_000_000 * 1e18;
    uint256 public constant AIRDROP_SUPPLY = 3_000_000 * 1e18;
    uint256 public constant FOUNDATION_SUPPLY = 1_000_000 * 1e18;
    uint256 public constant LIQUIDITY_SUPPLY = 1_000_000 * 1e18;
    uint256 public constant TEAM_SUPPLY = 1_000_000 * 1e18;

    // ----- Wallets -----
    address public foundationWallet;
    address public relayerWallet;
    address public teamWallet;

    // ----- Price -----
    uint256 public fluidPriceUSDT6 = 1e6;

    // ----- Chainlink feeds -----
    mapping(address => AggregatorV3Interface) public priceFeeds;
    AggregatorV3Interface public nativePriceFeed;

    // ----- Sale tracking -----
    uint256 public fluidSold;

    // ----- Airdrop -----
    struct AirdropInfo {
        uint256 totalAllocated;
        uint8 claimedYears;
        uint256 startTime;
        bool completed;
    }
    mapping(address => AirdropInfo) public airdrops;
    uint256 public distributedAirdrops;
    bool public airdropActive = true;
    uint8 public constant AIRDROP_YEARS = 10;

    // ----- CEX Liquidity -----
    mapping(address => uint256) public cexAllocation;
    mapping(address => bool) public cexClaimed;

    // ----- Events -----
    event PriceUpdated(uint256 newPriceUSDT6);
    event PriceFeedSet(address token, address feed);
    event NativeFeedSet(address feed);
    event FoundationWalletUpdated(address newWallet);
    event RelayerWalletUpdated(address newWallet);
    event SaleExecuted(address indexed buyer, address payToken, uint256 payAmount, uint256 fluidAmount);
    event AirdropAllocated(address indexed user, uint256 amount);
    event AirdropClaimed(address indexed user, uint256 amount, uint8 year);
    event TokensBurned(address indexed from, uint256 amount);
    event TokensMinted(address indexed to, uint256 amount);
    event CEXAllocated(address indexed cex, uint256 amount);
    event CEXClaimed(address indexed cex, uint256 amount);

    constructor(
        address _foundationWallet,
        address _relayerWallet,
        address _teamWallet
    ) ERC20("Fluid Token", "FLUID") {
        require(_foundationWallet != address(0), "invalid foundation wallet");
        require(_relayerWallet != address(0), "invalid relayer wallet");
        require(_teamWallet != address(0), "invalid team wallet");

        foundationWallet = _foundationWallet;
        relayerWallet = _relayerWallet;
        teamWallet = _teamWallet;

        _mint(address(this), MAX_SUPPLY); // All tokens minted to contract
    }

    // =========================
    // ===== Admin / Config ====
    // =========================
    function setFluidPriceUSDT6(uint256 priceUSDT6) external onlyOwner {
        require(priceUSDT6 > 0, "price>0");
        fluidPriceUSDT6 = priceUSDT6;
        emit PriceUpdated(priceUSDT6);
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        require(token != address(0) && feed != address(0), "zero addr");
        priceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedSet(token, feed);
    }

    function setNativePriceFeed(address feed) external onlyOwner {
        require(feed != address(0), "zero feed");
        nativePriceFeed = AggregatorV3Interface(feed);
        emit NativeFeedSet(feed);
    }

    function setFoundationWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "zero");
        foundationWallet = newWallet;
        emit FoundationWalletUpdated(newWallet);
    }

    function setRelayerWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "zero");
        relayerWallet = newWallet;
        emit RelayerWalletUpdated(newWallet);
    }

    function setAirdropActive(bool active) external onlyOwner {
        airdropActive = active;
    }

    function modifyUserAirdrop(address user, uint256 newTotal) external onlyOwner {
        require(user != address(0), "invalid user");
        AirdropInfo storage info = airdrops[user];
        require(!info.completed, "already completed");
        if (info.totalAllocated > distributedAirdrops) {
            distributedAirdrops = distributedAirdrops + newTotal - info.totalAllocated;
        } else {
            distributedAirdrops = distributedAirdrops - info.totalAllocated + newTotal;
        }
        info.totalAllocated = newTotal;
    }

    // =========================
    // ===== Burn / Mint =======
    // =========================
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    function mintCrossChain(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "exceeds max supply");
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    // =========================
    // ======== BUYING =========
    // =========================
    function buyWithERC20AndGas(address payToken, uint256 payAmount, uint256 gasFee) external {
        require(payAmount > gasFee, "payAmount must > gasFee");
        require(relayerWallet != address(0) && foundationWallet != address(0), "wallets not set");
        require(address(priceFeeds[payToken]) != address(0), "no feed");

        uint256 saleAmount = payAmount - gasFee;
        if(gasFee > 0) IERC20(payToken).safeTransferFrom(msg.sender, relayerWallet, gasFee);
        IERC20(payToken).safeTransferFrom(msg.sender, foundationWallet, saleAmount);

        AggregatorV3Interface feed = priceFeeds[payToken];
        (, int256 price,,,) = feed.latestRoundData();
        require(price > 0, "invalid feed");
        uint8 aggDecimals = feed.decimals();
        uint8 tokenDecimals;
        try IERC20Metadata(payToken).decimals() returns (uint8 d) { tokenDecimals = d; } catch { tokenDecimals = 18; }

        uint256 usd18 = (saleAmount * uint256(price) * 1e18) / ((10 ** tokenDecimals) * (10 ** aggDecimals));
        uint256 fluidAmount = (usd18 * 1e6) / fluidPriceUSDT6;
        require(balanceOf(address(this)) >= fluidAmount, "contract lacks FLUID");
        require(fluidSold + fluidAmount <= PRESALE_SUPPLY, "sale supply exceeded");

        _transfer(address(this), msg.sender, fluidAmount);
        fluidSold += fluidAmount;

        uint256 airdropAlloc = (fluidAmount * AIRDROP_SUPPLY) / PRESALE_SUPPLY;
        if (airdropAlloc > 0) _allocateAirdrop(msg.sender, airdropAlloc);

        emit SaleExecuted(msg.sender, payToken, payAmount, fluidAmount);
    }

    function buyWithNativeAndGas(uint256 gasFee) external payable {
        require(msg.value > gasFee, "msg.value <= gasFee");
        require(relayerWallet != address(0) && foundationWallet != address(0), "wallets not set");

        uint256 saleAmount = msg.value - gasFee;

        if(gasFee > 0) { (bool sentGas, ) = payable(relayerWallet).call{value: gasFee}(""); require(sentGas, "gas transfer failed"); }
        (bool sentSale, ) = payable(foundationWallet).call{value: saleAmount}(""); require(sentSale, "sale transfer failed");

        (, int256 answer,,,) = nativePriceFeed.latestRoundData();
        require(answer > 0, "invalid feed");
        uint8 aggDecimals = nativePriceFeed.decimals();
        uint256 usd18 = (saleAmount * uint256(answer) * 1e18) / (1e18 * (10 ** aggDecimals));
        uint256 fluidAmount = (usd18 * 1e6) / fluidPriceUSDT6;
        require(balanceOf(address(this)) >= fluidAmount, "contract lacks FLUID");
        require(fluidSold + fluidAmount <= PRESALE_SUPPLY, "sale supply exceeded");

        _transfer(address(this), msg.sender, fluidAmount);
        fluidSold += fluidAmount;

        uint256 airdropAlloc = (fluidAmount * AIRDROP_SUPPLY) / PRESALE_SUPPLY;
        if (airdropAlloc > 0) _allocateAirdrop(msg.sender, airdropAlloc);

        emit SaleExecuted(msg.sender, address(0), msg.value, fluidAmount);
    }

    // =========================
    // ======= AIRDROPS ========
    // =========================
    function _allocateAirdrop(address user, uint256 amount) internal {
        require(user != address(0) && amount > 0, "invalid");
        require(distributedAirdrops + amount <= AIRDROP_SUPPLY, "exceeds pool");

        AirdropInfo storage info = airdrops[user];
        uint256 alloc = info.totalAllocated;
        if(alloc == 0) info.startTime = block.timestamp;
        info.totalAllocated = alloc + amount;
        distributedAirdrops += amount;

        emit AirdropAllocated(user, amount);
    }

    function claimAirdrop() external {
        require(airdropActive, "airdrops paused");

        AirdropInfo storage info = airdrops[msg.sender];
        require(info.totalAllocated > 0 && !info.completed, "none or done");

        uint256 yearsSince = (block.timestamp - info.startTime) / 365 days;
        require(yearsSince >= 1, "first claim not yet");

        uint8 currentYear = uint8(yearsSince);
        require(info.claimedYears + 1 == currentYear, "already claimed/missed");

        uint256 perYear = info.totalAllocated / AIRDROP_YEARS;
        unchecked { info.claimedYears += 1; }
        if(info.claimedYears == AIRDROP_YEARS) info.completed = true;

        _transfer(address(this), msg.sender, perYear);
        emit AirdropClaimed(msg.sender, perYear, currentYear);
    }

    // =========================
    // ===== CEX Liquidity ======
    // =========================
    function allocateLiquidityToCEX(address cex, uint256 amount) external onlyOwner {
        require(cex != address(0), "invalid wallet");
        require(amount > 0, "invalid amount");
        require(cexAllocation[cex] == 0, "already allocated");
        require(balanceOf(address(this)) >= amount, "not enough liquidity");

        cexAllocation[cex] = amount;
        emit CEXAllocated(cex, amount);
    }

    function claimLiquidity() external {
        uint256 amount = cexAllocation[msg.sender];
        require(amount > 0, "no allocation");
        require(!cexClaimed[msg.sender], "already claimed");

        cexClaimed[msg.sender] = true;
        _transfer(address(this), msg.sender, amount);
        emit CEXClaimed(msg.sender, amount);
    }

    // fallback to receive native
    receive() external payable {}
}
