// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract OnePageLiquidity is ReentrancyGuard {
    address public creator;
    address public platformWallet; // OnePage's wallet to collect platform fees
    uint256 public platformFeeBPS; // Platform fee in basis points (e.g., 10 for 0.1%)

    // Events for logging actions
    event PairAdded(address indexed tokenA, address indexed tokenB, uint256 fee);
    event PairRemoved(address indexed tokenA, address indexed tokenB);
    event LiquidityDeposited(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);
    event Swapped(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event LiquidityWithdrawn(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);

    struct Pair {
        address tokenA;
        address tokenB;
        uint256 reserveA;
        uint256 reserveB;
        uint256 fee; // Creator's fee in basis points (e.g., 30 for 0.3%)
    }

    struct PairKey {
        address tokenA;
        address tokenB;
    }

    mapping(address => mapping(address => Pair)) public pairs;
    PairKey[] public pairKeys;

    modifier onlyCreator() {
        require(msg.sender == creator, "Only creator can call this function");
        _;
    }

    constructor(address _creator, address _platformWallet, uint256 _platformFeeBPS) {
        require(_creator != address(0) && _platformWallet != address(0), "Invalid address");
        creator = _creator;
        platformWallet = _platformWallet;
        platformFeeBPS = _platformFeeBPS;
    }

    // **Add a new token pair**
    function addPair(address tokenA, address tokenB, uint256 fee) external onlyCreator {
        require(tokenA != address(0) && tokenB != address(0), "Invalid token address");
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        require(pairs[tokenA][tokenB].tokenA == address(0), "Pair already exists");

        pairs[tokenA][tokenB] = Pair(tokenA, tokenB, 0, 0, fee);
        pairKeys.push(PairKey(tokenA, tokenB));

        emit PairAdded(tokenA, tokenB, fee);
    }

    // **Remove a token pair**
    function removePair(address tokenA, address tokenB) external onlyCreator {
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        require(pairs[tokenA][tokenB].tokenA != address(0), "Pair does not exist");

        delete pairs[tokenA][tokenB];

        uint256 length = pairKeys.length;
        for (uint256 i = 0; i < length; i++) {
            if (pairKeys[i].tokenA == tokenA && pairKeys[i].tokenB == tokenB) {
                pairKeys[i] = pairKeys[length - 1];
                pairKeys.pop();
                break;
            }
        }

        emit PairRemoved(tokenA, tokenB);
    }

    // **Deposit liquidity into a pair**
    function depositLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external onlyCreator nonReentrant {
        require(amountA > 0 && amountB > 0, "Amounts must be greater than zero");
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
            (amountA, amountB) = (amountB, amountA);
        }
        Pair storage pair = pairs[tokenA][tokenB];
        require(pair.tokenA == tokenA, "Pair does not exist");

        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);

        pair.reserveA += amountA;
        pair.reserveB += amountB;

        emit LiquidityDeposited(tokenA, tokenB, amountA, amountB);
    }

    // **Swap tokens in a pair**
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external nonReentrant {
        require(amountIn > 0, "Amount in must be greater than zero");
        address tokenA = tokenIn < tokenOut ? tokenIn : tokenOut;
        address tokenB = tokenIn < tokenOut ? tokenOut : tokenIn;
        Pair storage pair = pairs[tokenA][tokenB];
        require(pair.tokenA == tokenA && pair.tokenB == tokenB, "Pair does not exist");

        uint256 reserveIn = tokenIn == tokenA ? pair.reserveA : pair.reserveB;
        uint256 reserveOut = tokenIn == tokenA ? pair.reserveB : pair.reserveA;
        require(reserveIn > 0 && reserveOut > 0, "Empty reserves");

        uint256 effectiveAmountIn = (amountIn * (10000 - pair.fee)) / 10000 - (amountIn * platformFeeBPS) / 10000;
        require(effectiveAmountIn > 0, "Effective amount too low");

        uint256 amountOut = (effectiveAmountIn * reserveOut) / ((reserveIn * 10000) + effectiveAmountIn);
        require(amountOut >= minAmountOut, "Slippage limit exceeded");
        require(reserveOut >= amountOut, "Insufficient liquidity");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 platformFee = (amountIn * platformFeeBPS) / 10000;
        IERC20(tokenIn).transfer(platformWallet, platformFee);
        IERC20(tokenOut).transfer(msg.sender, amountOut);

        if (tokenIn == tokenA) {
            pair.reserveA += effectiveAmountIn;
            pair.reserveB -= amountOut;
        } else {
            pair.reserveB += effectiveAmountIn;
            pair.reserveA -= amountOut;
        }

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // **Withdraw liquidity from a pair**
    function withdrawFromPair(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external onlyCreator nonReentrant {
        require(amountA > 0 && amountB > 0, "Withdrawal amounts must be greater than zero");
        if (tokenA > tokenB) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        Pair storage pair = pairs[tokenA][tokenB];
        require(pair.reserveA >= amountA, "Insufficient liquidity for tokenA");
        require(pair.reserveB >= amountB, "Insufficient liquidity for tokenB");

        pair.reserveA -= amountA;
        pair.reserveB -= amountB;

        IERC20(tokenA).transfer(creator, amountA);
        IERC20(tokenB).transfer(creator, amountB);

        emit LiquidityWithdrawn(tokenA, tokenB, amountA, amountB);
    }
}
