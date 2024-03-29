pragma solidity 0.4.25;

import "./ConversionRatesInterface.sol";
import "./LiquidityFormula.sol";
import "./Withdrawable.sol";
import "./Utils.sol";


contract LiquidityConversionRates is ConversionRatesInterface, LiquidityFormula, Withdrawable, Utils {
    TRC20 public token;
    address public reserveContract;

    uint public numFpBits;
    uint public formulaPrecision;

    uint public rInFp;
    uint public pMinInFp;

    uint public maxEthCapBuyInFp;
    uint public maxEthCapSellInFp;
    uint public maxQtyInFp;

    uint public feeInBps;
    uint public collectedFeesInTwei = 0;

    uint public maxBuyRateInPrecision;
    uint public minBuyRateInPrecision;
    uint public maxSellRateInPrecision;
    uint public minSellRateInPrecision;

    constructor(address _admin, TRC20 _token) public {
        transferAdminQuickly(_admin);
        token = _token;
        setDecimals(token);
        require(getDecimals(token) <= MAX_DECIMALS);
    }

    event ReserveAddressSet(address reserve);

    function setReserveAddress(address reserve) public onlyAdmin {
        reserveContract = reserve;
        emit ReserveAddressSet(reserve);
    }

    event LiquidityParamsSet(
        uint rInFp,
        uint pMinInFp,
        uint numFpBits,
        uint maxCapBuyInFp,
        uint maxEthCapSellInFp,
        uint feeInBps,
        uint formulaPrecision,
        uint maxQtyInFp,
        uint maxBuyRateInPrecision,
        uint minBuyRateInPrecision,
        uint maxSellRateInPrecision,
        uint minSellRateInPrecision
    );

    function setLiquidityParams(
        uint _rInFp,
        uint _pMinInFp,
        uint _numFpBits,
        uint _maxCapBuyInWei,
        uint _maxCapSellInWei,
        uint _feeInBps,
        uint _maxTokenToEthRateInPrecision,
        uint _minTokenToEthRateInPrecision
    ) public onlyAdmin {

        require(_numFpBits < 256);
        require(formulaPrecision <= MAX_QTY);
        require(_feeInBps < 10000);
        require(_minTokenToEthRateInPrecision < _maxTokenToEthRateInPrecision);

        rInFp = _rInFp;
        pMinInFp = _pMinInFp;
        formulaPrecision = uint(1)<<_numFpBits;
        maxQtyInFp = fromWeiToFp(MAX_QTY);
        numFpBits = _numFpBits;
        maxEthCapBuyInFp = fromWeiToFp(_maxCapBuyInWei);
        maxEthCapSellInFp = fromWeiToFp(_maxCapSellInWei);
        feeInBps = _feeInBps;
        maxBuyRateInPrecision = PRECISION * PRECISION / _minTokenToEthRateInPrecision;
        minBuyRateInPrecision = PRECISION * PRECISION / _maxTokenToEthRateInPrecision;
        maxSellRateInPrecision = _maxTokenToEthRateInPrecision;
        minSellRateInPrecision = _minTokenToEthRateInPrecision;

        emit LiquidityParamsSet(
            rInFp,
            pMinInFp,
            numFpBits,
            maxEthCapBuyInFp,
            maxEthCapSellInFp,
            feeInBps,
            formulaPrecision,
            maxQtyInFp,
            maxBuyRateInPrecision,
            minBuyRateInPrecision,
            maxSellRateInPrecision,
            minSellRateInPrecision
        );
    }

    function recordImbalance(
        TRC20 conversionToken,
        int buyAmountInTwei,
        uint rateUpdateBlock,
        uint currentBlock
    )
        public
    {
        conversionToken;
        rateUpdateBlock;
        currentBlock;

        require(msg.sender == reserveContract);
        if (buyAmountInTwei > 0) {
            // Buy case
            collectedFeesInTwei += calcCollectedFee(abs(buyAmountInTwei));
        } else {
            // Sell case
            collectedFeesInTwei += abs(buyAmountInTwei) * feeInBps / 10000;
        }
    }

    event CollectedFeesReset(uint resetFeesInTwei);

    function resetCollectedFees() public onlyAdmin {
        uint resetFeesInTwei = collectedFeesInTwei;
        collectedFeesInTwei = 0;

        emit CollectedFeesReset(resetFeesInTwei);
    }

    function getRate(
            TRC20 conversionToken,
            uint currentBlockNumber,
            bool buy,
            uint qtyInSrcWei
    ) public view returns(uint) {

        currentBlockNumber;

        require(qtyInSrcWei <= MAX_QTY);
        uint eInFp = fromWeiToFp(reserveContract.balance);
        uint rateInPrecision = getRateWithE(conversionToken, buy, qtyInSrcWei, eInFp);
        require(rateInPrecision <= MAX_RATE);
        return rateInPrecision;
    }

    function getRateWithE(TRC20 conversionToken, bool buy, uint qtyInSrcWei, uint eInFp) public view returns(uint) {
        uint deltaEInFp;
        uint sellInputTokenQtyInFp;
        uint deltaTInFp;
        uint rateInPrecision;

        require(qtyInSrcWei <= MAX_QTY);
        require(eInFp <= maxQtyInFp);
        if (conversionToken != token) return 0;

        if (buy) {
            // ETH goes in, token goes out
            deltaEInFp = fromWeiToFp(qtyInSrcWei);
            if (deltaEInFp > maxEthCapBuyInFp) return 0;

            if (deltaEInFp == 0) {
                rateInPrecision = buyRateZeroQuantity(eInFp);
            } else {
                rateInPrecision = buyRate(eInFp, deltaEInFp);
            }
        } else {
            sellInputTokenQtyInFp = fromTweiToFp(qtyInSrcWei);
            deltaTInFp = valueAfterReducingFee(sellInputTokenQtyInFp);
            if (deltaTInFp == 0) {
                rateInPrecision = sellRateZeroQuantity(eInFp);
                deltaEInFp = 0;
            } else {
                (rateInPrecision, deltaEInFp) = sellRate(eInFp, sellInputTokenQtyInFp, deltaTInFp);
            }

            if (deltaEInFp > maxEthCapSellInFp) return 0;
        }

        rateInPrecision = rateAfterValidation(rateInPrecision, buy);
        return rateInPrecision;
    }

    function rateAfterValidation(uint rateInPrecision, bool buy) public view returns(uint) {
        uint minAllowRateInPrecision;
        uint maxAllowedRateInPrecision;

        if (buy) {
            minAllowRateInPrecision = minBuyRateInPrecision;
            maxAllowedRateInPrecision = maxBuyRateInPrecision;
        } else {
            minAllowRateInPrecision = minSellRateInPrecision;
            maxAllowedRateInPrecision = maxSellRateInPrecision;
        }

        if ((rateInPrecision > maxAllowedRateInPrecision) || (rateInPrecision < minAllowRateInPrecision)) {
            return 0;
        } else if (rateInPrecision > MAX_RATE) {
            return 0;
        } else {
            return rateInPrecision;
        }
    }

    function buyRate(uint eInFp, uint deltaEInFp) public view returns(uint) {
        uint deltaTInFp = deltaTFunc(rInFp, pMinInFp, eInFp, deltaEInFp, formulaPrecision);
        require(deltaTInFp <= maxQtyInFp);
        deltaTInFp = valueAfterReducingFee(deltaTInFp);
        return deltaTInFp * PRECISION / deltaEInFp;
    }

    function buyRateZeroQuantity(uint eInFp) public view returns(uint) {
        uint ratePreReductionInPrecision = formulaPrecision * PRECISION / pE(rInFp, pMinInFp, eInFp, formulaPrecision);
        return valueAfterReducingFee(ratePreReductionInPrecision);
    }

    function sellRate(
        uint eInFp,
        uint sellInputTokenQtyInFp,
        uint deltaTInFp
    ) public view returns(uint rateInPrecision, uint deltaEInFp) {
        deltaEInFp = deltaEFunc(rInFp, pMinInFp, eInFp, deltaTInFp, formulaPrecision, numFpBits);
        require(deltaEInFp <= maxQtyInFp);
        rateInPrecision = deltaEInFp * PRECISION / sellInputTokenQtyInFp;
    }

    function sellRateZeroQuantity(uint eInFp) public view returns(uint) {
        uint ratePreReductionInPrecision = pE(rInFp, pMinInFp, eInFp, formulaPrecision) * PRECISION / formulaPrecision;
        return valueAfterReducingFee(ratePreReductionInPrecision);
    }

    function fromTweiToFp(uint qtyInTwei) public view returns(uint) {
        require(qtyInTwei <= MAX_QTY);
        return qtyInTwei * formulaPrecision / (10 ** getDecimals(token));
    }

    function fromWeiToFp(uint qtyInwei) public view returns(uint) {
        require(qtyInwei <= MAX_QTY);
        return qtyInwei * formulaPrecision / (10 ** TOMO_DECIMALS);
    }

    function valueAfterReducingFee(uint val) public view returns(uint) {
        require(val <= BIG_NUMBER);
        return ((10000 - feeInBps) * val) / 10000;
    }

    function calcCollectedFee(uint val) public view returns(uint) {
        require(val <= MAX_QTY);
        return val * feeInBps / (10000 - feeInBps);
    }

    function abs(int val) public pure returns(uint) {
        if (val < 0) {
            return uint(val * (-1));
        } else {
            return uint(val);
        }
    }

}
