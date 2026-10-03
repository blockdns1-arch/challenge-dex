// SPDX-License-Identifier: MIT
pragma solidity 0.8.20; //Do not change the solidity version as it negatively impacts submission grading

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DEX {
    /////////////////
    /// Errors //////
    /////////////////

    error DexAlreadyInitialized(); //  Already initialized
    error TokenTransferFailed(); //  token transfer failed
    error InvalidEthAmount(); //  invalid ETH amount
    error InvalidTokenAmount(); // invalid token amount
    error InsufficientTokenBalance(uint256 available, uint256 required); // insufficient token balance
    error InsufficientTokenAllowance(uint256 available, uint256 required); // insufficient token allowance
    error EthTransferFailed(address to, uint256 amount); // ETH transfer failed
    error InsufficientLiquidity(uint256 available, uint256 required); // insufficient liquidity

    //////////////////////
    /// State Variables //
    //////////////////////

    IERC20 public immutable token; // The token that will be used in the DEX

    uint256 public totalLiquidity; // The total amount of liquidity in the DEX

    mapping(address => uint256) public liquidity; // The amount of liquidity that each address has provided

    ////////////////
    /// Events /////
    ////////////////

    event EthToTokenSwap(address swapper, uint256 tokenOutput, uint256 ethInput); // Emitted when a user swaps ETH for tokens
    event TokenToEthSwap(address swapper, uint256 tokensInput, uint256 ethOutput); // Emitted when a user swaps tokens for ETH
    event LiquidityProvided(address liquidityProvider, uint256 liquidityMinted, uint256 ethInput, uint256 tokensInput); // Emitted when liquidity is provided
    event LiquidityRemoved(address liquidityRemover, uint256 liquidityWithdrawn, uint256 tokensOutput, uint256 ethOutput); // Emitted when liquidity is removed

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address tokenAddr) {
        token = IERC20(tokenAddr);
    }

    ///////////////////
    /// Functions /////
    ///////////////////

    /**
     * @notice Initializes the DEX by setting the initial liquidity to the amount of ETH sent by the initializer.
     * @dev The initial liquidity provider must approve the DEX to spend the tokens before calling this function.
     * @param tokens The amount of tokens to be deposited by the initializer.
     * @return initialLiquidity The amount of liquidity minted for the initializer.
     */
    function init(uint256 tokens) public payable returns (uint256 initialLiquidity) {
        if (totalLiquidity != 0) revert DexAlreadyInitialized();
        if (msg.value <= 0) revert InvalidEthAmount();
        if (tokens <= 0) revert InvalidTokenAmount();

        uint256 allowed = token.allowance(msg.sender, address(this));
        if (allowed < tokens) revert InsufficientTokenAllowance(allowed, tokens);

        bool sent = token.transferFrom(msg.sender, address(this), tokens);
        if (!sent) revert TokenTransferFailed();

        initialLiquidity = msg.value;
        liquidity[msg.sender] = initialLiquidity;
        totalLiquidity = initialLiquidity;
    }

    /**
     * @notice Calculates the output amount of y for a given input amount of x, using the constant product formula with a 0.3% fee.
     * @dev The fee is applied to the input before the curve is applied, so the fee is never taken out of the output.
     * @param xInput The amount of x being swapped in.
     * @param xReserves The reserves of x in the pool.
     * @param yReserves The reserves of y in the pool.
     * @return yOutput The amount of y that would be received for the given xInput.
     */
    function price(uint256 xInput, uint256 xReserves, uint256 yReserves) public pure returns (uint256 yOutput) {
        uint256 xInputWithFee = xInput * 997;
        uint256 numerator = xInputWithFee * yReserves;
        uint256 denominator = xReserves * 1000 + xInputWithFee;
        yOutput = numerator / denominator;
    }

    function getLiquidity(address lp) public view returns (uint256 lpLiquidity) {
        lpLiquidity = liquidity[lp];
    }

    /**
     * @notice Swaps ETH for tokens.
     * @dev Reserves are read before the incoming ETH is applied, then the curve is used to price the trade.
     * @return tokenOutput The amount of tokens received by the swapper.
     */
    function ethToToken() public payable returns (uint256 tokenOutput) {
        if (msg.value <= 0) revert InvalidEthAmount();

        uint256 xReserves = address(this).balance - msg.value;
        uint256 yReserves = token.balanceOf(address(this));

        tokenOutput = price(msg.value, xReserves, yReserves);
        if (tokenOutput <= 0) revert InvalidTokenAmount();

        bool sent = token.transfer(msg.sender, tokenOutput);
        if (!sent) revert TokenTransferFailed();

        emit EthToTokenSwap(msg.sender, tokenOutput, msg.value);
    }

    /**
     * @notice Swaps tokens for ETH.
     * @dev The swapper must approve the DEX to spend `tokenInput` tokens before calling this function.
     * @param tokenInput The amount of tokens being swapped in.
     * @return ethOutput The amount of ETH received by the swapper.
     */
    function tokenToEth(uint256 tokenInput) public returns (uint256 ethOutput) {
        if (tokenInput <= 0) revert InvalidTokenAmount();

        uint256 xReserves = token.balanceOf(address(this));
        uint256 yReserves = address(this).balance;

        ethOutput = price(tokenInput, xReserves, yReserves);
        if (ethOutput <= 0) revert InvalidEthAmount();

        uint256 balance = token.balanceOf(msg.sender);
        if (balance < tokenInput) revert InsufficientTokenBalance(balance, tokenInput);

        uint256 allowed = token.allowance(msg.sender, address(this));
        if (allowed < tokenInput) revert InsufficientTokenAllowance(allowed, tokenInput);

        bool sent = token.transferFrom(msg.sender, address(this), tokenInput);
        if (!sent) revert TokenTransferFailed();

        (bool success, ) = msg.sender.call{ value: ethOutput }("");
        if (!success) revert EthTransferFailed(msg.sender, ethOutput);

        emit TokenToEthSwap(msg.sender, tokenInput, ethOutput);
    }

    /**
     * @notice Adds liquidity to the DEX at the current pool ratio.
     * @dev The depositor must send ETH and approve the matching amount of tokens. One extra wei of
     * tokens is pulled to round the required amount up, so integer truncation can never under-collateralize the pool.
     * @return tokensDeposited The amount of tokens pulled from the depositor.
     */
    function deposit() public payable returns (uint256 tokensDeposited) {
        if (msg.value <= 0) revert InvalidEthAmount();

        uint256 ethReserves = address(this).balance - msg.value;
        uint256 tokenReserves = token.balanceOf(address(this));
        tokensDeposited = (msg.value * tokenReserves / ethReserves) + 1;

        uint256 balance = token.balanceOf(msg.sender);
        if (balance < tokensDeposited) revert InsufficientTokenBalance(balance, tokensDeposited);

        uint256 allowed = token.allowance(msg.sender, address(this));
        if (allowed < tokensDeposited) revert InsufficientTokenAllowance(allowed, tokensDeposited);

        bool sent = token.transferFrom(msg.sender, address(this), tokensDeposited);
        if (!sent) revert TokenTransferFailed();

        uint256 liquidityMinted = (msg.value * totalLiquidity) / ethReserves;
        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        emit LiquidityProvided(msg.sender, liquidityMinted, msg.value, tokensDeposited);
    }

    /**
     * @notice Burns LP tokens and returns the proportional share of the pool's ETH and tokens.
     * @param amount The amount of LP tokens to burn.
     * @return ethAmount The amount of ETH returned to the liquidity remover.
     * @return tokenAmount The amount of tokens returned to the liquidity remover.
     */
    function withdraw(uint256 amount) public returns (uint256 ethAmount, uint256 tokenAmount) {
        uint256 userLiquidity = liquidity[msg.sender];
        if (userLiquidity < amount) revert InsufficientLiquidity(userLiquidity, amount);

        uint256 totalLiquidityBefore = totalLiquidity;
        uint256 ethReserves = address(this).balance;
        uint256 tokenReserves = token.balanceOf(address(this));

        ethAmount = (amount * ethReserves) / totalLiquidityBefore;
        tokenAmount = (amount * tokenReserves) / totalLiquidityBefore;

        liquidity[msg.sender] -= amount;
        totalLiquidity -= amount;

        bool sent = token.transfer(msg.sender, tokenAmount);
        if (!sent) revert TokenTransferFailed();

        (bool success, ) = msg.sender.call{ value: ethAmount }("");
        if (!success) revert EthTransferFailed(msg.sender, ethAmount);

        emit LiquidityRemoved(msg.sender, amount, tokenAmount, ethAmount);
    }
}
