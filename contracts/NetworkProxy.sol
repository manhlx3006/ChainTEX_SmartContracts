pragma solidity 0.4.25;

import "./TRC20Interface.sol";
import "./Withdrawable.sol";
import "./Utils2.sol";
import "./NetworkInterface.sol";
import "./NetworkProxyInterface.sol";
import "./SimpleNetworkInterface.sol";


////////////////////////////////////////////////////////////////////////////////////////////////////////
/// @title Network proxy for main contract
contract NetworkProxy is NetworkProxyInterface, SimpleNetworkInterface, Withdrawable, Utils2 {

    NetworkInterface public networkContract;

    constructor(address _admin) public {
        require(_admin != address(0));
        admin = _admin;
    }

    /// @notice use token address TOMO_TOKEN_ADDRESS for TOMO
    /// @dev makes a trade between src and dest token and send dest token to destAddress
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @param dest   Destination token
    /// @param destAddress Address to send tokens to
    /// @param maxDestAmount A limit on the amount of dest tokens
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @param walletId is the wallet ID to send part of the fees
    /// @return amount of actual dest tokens
    function trade(
        TRC20 src,
        uint srcAmount,
        TRC20 dest,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate,
        address walletId
    )
        public
        payable
        returns(uint)
    {
        bytes memory hint;

        return tradeWithHint(
            src,
            srcAmount,
            dest,
            destAddress,
            maxDestAmount,
            minConversionRate,
            walletId,
            hint
        );
    }

    /// @notice use token address TOMO_TOKEN_ADDRESS for TOMO
    /// @dev makes a trade for transaction fee
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @param destAddress Address to send tokens to
    /// @param maxDestAmount A limit on the amount of dest tokens
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @return amount of actual dest tokens
    function payTxFee(
        TRC20 src,
        uint srcAmount,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate
    )
        public
        payable
        returns(uint)
    {
        require(src == TOMO_TOKEN_ADDRESS || msg.value == 0);
        TRC20 dest = TOMO_TOKEN_ADDRESS;

        UserBalance memory userBalanceBefore;

        userBalanceBefore.srcBalance = getBalance(src, msg.sender);
        userBalanceBefore.destBalance = getBalance(dest, destAddress);

        if (src == TOMO_TOKEN_ADDRESS) {
            userBalanceBefore.srcBalance += msg.value;
        } else {
            require(src.transferFrom(msg.sender, networkContract, srcAmount), "payTxFee: Transer token to network contract");
        }

        uint reportedDestAmount = networkContract.payTxFee.value(msg.value)(
          msg.sender,
          src,
          srcAmount,
          destAddress,
          maxDestAmount,
          minConversionRate
        );

        TradeOutcome memory tradeOutcome = calculateTradeOutcome(
            userBalanceBefore.srcBalance,
            userBalanceBefore.destBalance,
            src,
            dest,
            destAddress
        );

        require(reportedDestAmount == tradeOutcome.userDeltaDestAmount, "Report dest amount is different from user delta dest amount");
        require(tradeOutcome.userDeltaDestAmount <= maxDestAmount, "userDetalDestAmount > maxDestAmount");
        require(tradeOutcome.actualRate >= minConversionRate, "actualRate < minConversionRate");

        emit ExecuteTrade(msg.sender, src, dest, tradeOutcome.userDeltaSrcAmount, tradeOutcome.userDeltaDestAmount);
        return tradeOutcome.userDeltaDestAmount;
    }

    /// @notice use token address TOMO_TOKEN_ADDRESS for TOMO
    /// @dev makes a trade for transaction fee
    /// @dev auto set maxDestAmount and minConversionRate
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @param destAddress Address to send tokens to
    /// @return amount of actual dest tokens
    function payTxFeeFast(TRC20 src, uint srcAmount, address destAddress) external payable returns(uint) {
      payTxFee(
        src,
        srcAmount,
        destAddress,
        MAX_QTY,
        0
      );
    }

    /// @dev makes a trade between src and dest token and send dest tokens to msg sender
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @param dest Destination token
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @return amount of actual dest tokens
    function swapTokenToToken(
        TRC20 src,
        uint srcAmount,
        TRC20 dest,
        uint minConversionRate
    )
        public
        returns(uint)
    {
        bytes memory hint;

        return tradeWithHint(
            src,
            srcAmount,
            dest,
            msg.sender,
            MAX_QTY,
            minConversionRate,
            0,
            hint
        );
    }

    /// @dev makes a trade from Tomo to token. Sends token to msg sender
    /// @param token Destination token
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @return amount of actual dest tokens
    function swapTomoToToken(TRC20 token, uint minConversionRate) public payable returns(uint) {
        bytes memory hint;

        return tradeWithHint(
            TOMO_TOKEN_ADDRESS,
            msg.value,
            token,
            msg.sender,
            MAX_QTY,
            minConversionRate,
            0,
            hint
        );
    }

    /// @dev makes a trade from token to Tomo, sends Ether to msg sender
    /// @param token Src token
    /// @param srcAmount amount of src tokens
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @return amount of actual dest tokens
    function swapTokenToTomo(TRC20 token, uint srcAmount, uint minConversionRate) public returns(uint) {
        bytes memory hint;

        return tradeWithHint(
            token,
            srcAmount,
            TOMO_TOKEN_ADDRESS,
            msg.sender,
            MAX_QTY,
            minConversionRate,
            0,
            hint
        );
    }

    struct UserBalance {
        uint srcBalance;
        uint destBalance;
    }

    event ExecuteTrade(address indexed trader, TRC20 src, TRC20 dest, uint actualSrcAmount, uint actualDestAmount);

    /// @notice use token address TOMO_TOKEN_ADDRESS for ether
    /// @dev makes a trade between src and dest token and send dest token to destAddress
    /// @param src Src token
    /// @param srcAmount amount of src tokens
    /// @param dest Destination token
    /// @param destAddress Address to send tokens to
    /// @param maxDestAmount A limit on the amount of dest tokens
    /// @param minConversionRate The minimal conversion rate. If actual rate is lower, trade is canceled.
    /// @param walletId is the wallet ID to send part of the fees
    /// @param hint will give hints for the trade.
    /// @return amount of actual dest tokens
    function tradeWithHint(
        TRC20 src,
        uint srcAmount,
        TRC20 dest,
        address destAddress,
        uint maxDestAmount,
        uint minConversionRate,
        address walletId,
        bytes memory hint
    )
        public
        payable
        returns(uint)
    {
        require(src == TOMO_TOKEN_ADDRESS || msg.value == 0);

        UserBalance memory userBalanceBefore;

        userBalanceBefore.srcBalance = getBalance(src, msg.sender);
        userBalanceBefore.destBalance = getBalance(dest, destAddress);

        if (src == TOMO_TOKEN_ADDRESS) {
            userBalanceBefore.srcBalance += msg.value;
        } else {
            require(src.transferFrom(msg.sender, networkContract, srcAmount), "tradeWithHint: Can not transfer token to contract");
        }

        uint reportedDestAmount = networkContract.tradeWithHint.value(msg.value)(
            msg.sender,
            src,
            srcAmount,
            dest,
            destAddress,
            maxDestAmount,
            minConversionRate,
            walletId,
            hint
        );

        TradeOutcome memory tradeOutcome = calculateTradeOutcome(
            userBalanceBefore.srcBalance,
            userBalanceBefore.destBalance,
            src,
            dest,
            destAddress
        );

        require(reportedDestAmount == tradeOutcome.userDeltaDestAmount);
        require(tradeOutcome.userDeltaDestAmount <= maxDestAmount);
        require(tradeOutcome.actualRate >= minConversionRate);

        emit ExecuteTrade(msg.sender, src, dest, tradeOutcome.userDeltaSrcAmount, tradeOutcome.userDeltaDestAmount);
        return tradeOutcome.userDeltaDestAmount;
    }

    event NetworkSet(address newNetworkContract, address oldNetworkContract);

    function setnetworkContract(NetworkInterface _networkContract) public onlyAdmin {

        require(_networkContract != address(0));

        emit NetworkSet(_networkContract, networkContract);

        networkContract = _networkContract;
    }

    function getExpectedRate(TRC20 src, TRC20 dest, uint srcQty)
        public view
        returns(uint expectedRate, uint slippageRate)
    {
        return networkContract.getExpectedRate(src, dest, srcQty);
    }

    function getExpectedFeeRate(TRC20 token, uint srcQty)
        public view
        returns (uint expectedRate, uint slippageRate)
    {
        return networkContract.getExpectedFeeRate(token, srcQty);
    }

    function getUserCapInWei(address user) public view returns(uint) {
        return networkContract.getUserCapInWei(user);
    }

    function getUserCapInTokenWei(address user, TRC20 token) public view returns(uint) {
        return networkContract.getUserCapInTokenWei(user, token);
    }

    function maxGasPrice() public view returns(uint) {
        return networkContract.maxGasPrice();
    }

    function enabled() public view returns(bool) {
        return networkContract.enabled();
    }

    function info(bytes32 field) public view returns(uint) {
        return networkContract.info(field);
    }

    struct TradeOutcome {
        uint userDeltaSrcAmount;
        uint userDeltaDestAmount;
        uint actualRate;
    }

    function calculateTradeOutcome (uint srcBalanceBefore, uint destBalanceBefore, TRC20 src, TRC20 dest,
        address destAddress)
        internal returns(TradeOutcome memory outcome)
    {
        uint userSrcBalanceAfter;
        uint userDestBalanceAfter;

        userSrcBalanceAfter = getBalance(src, msg.sender);
        userDestBalanceAfter = getBalance(dest, destAddress);

        //protect from underflow
        require(userDestBalanceAfter > destBalanceBefore, "userDestBalanceAfter <= destBalanceBefore");
        require(srcBalanceBefore > userSrcBalanceAfter, "srcBalanceBefore <= userSrcBalanceAfter");

        outcome.userDeltaDestAmount = userDestBalanceAfter - destBalanceBefore;
        outcome.userDeltaSrcAmount = srcBalanceBefore - userSrcBalanceAfter;

        outcome.actualRate = calcRateFromQty(
                outcome.userDeltaSrcAmount,
                outcome.userDeltaDestAmount,
                getDecimalsSafe(src),
                getDecimalsSafe(dest)
            );
    }
}
