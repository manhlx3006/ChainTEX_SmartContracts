pragma solidity 0.4.25;


import "./TRC20Interface.sol";
import "./VolumeImbalanceRecorder.sol";
import "./Utils.sol";
import "./ConversionRatesInterface.sol";

contract SimpleConversionRates is ConversionRatesInterface, VolumeImbalanceRecorder, Utils {

  // bps - basic rate steps. one step is 1 / 10000 of the rate.
  struct StepFunction {
    int[] x; // quantity for each step. Quantity of each step includes previous steps.
    int[] y; // rate change per quantity step  in bps.
  }

  struct TokenData {
    bool listed;  // was added to reserve
    bool enabled; // whether trade is enabled
    uint lastUpdatedBlock;

    // rate data. base and changes according to quantity and reserve balance.
    // generally speaking. Sell rate is 1 / buy rate i.e. the buy in the other direction.
    uint baseBuyRate;  // in PRECISION units. see KyberConstants
    uint baseSellRate; // PRECISION units. without (sell / buy) spread it is 1 / baseBuyRate
    StepFunction buyRateQtyStepFunction; // in bps. higher quantity - bigger the rate.
    StepFunction sellRateQtyStepFunction;// in bps. higher the qua
    StepFunction buyRateImbalanceStepFunction; // in BPS. higher reserve imbalance - bigger the rate.
    StepFunction sellRateImbalanceStepFunction;
  }

  uint public validRateDurationInBlocks = 10; // rates are valid for this amount of blocks
  TRC20[] internal listedTokens;
  mapping(address=>TokenData) internal tokenData;
  address public reserveContract;
  uint constant internal MAX_STEPS_IN_FUNCTION = 10;
  int constant internal MAX_BPS_ADJUSTMENT = 10 ** 11; // 1B %
  int constant internal MIN_BPS_ADJUSTMENT = -100 * 100; // cannot go down by more than 100%

  constructor(address _admin) public VolumeImbalanceRecorder(_admin)
  { } // solhint-disable-line no-empty-blocks

  function addToken(TRC20 token) public onlyAdmin {

    require(!tokenData[token].listed);
    tokenData[token].listed = true;
    listedTokens.push(token);

    setGarbageToVolumeRecorder(token);

    setDecimals(token);
  }

  function setBaseRates(
    TRC20[] memory tokens,
    uint[] memory baseBuy,
    uint[] memory baseSell,
    uint blockNumber
  )
  public
  onlyOperator
  {
    require(tokens.length == baseBuy.length);
    require(tokens.length == baseSell.length);

    for (uint ind = 0; ind < tokens.length; ind++) {
      require(tokenData[tokens[ind]].listed);
      tokenData[tokens[ind]].baseBuyRate = baseBuy[ind];
      tokenData[tokens[ind]].baseSellRate = baseSell[ind];
      tokenData[tokens[ind]].lastUpdatedBlock = blockNumber;
    }
  }

  function setQtyStepFunction(
    TRC20 token,
    int[] memory xBuy,
    int[] memory yBuy,
    int[] memory xSell,
    int[] memory ySell
  )
  public
  onlyOperator
  {
    require(xBuy.length == yBuy.length);
    require(xSell.length == ySell.length);
    require(xBuy.length <= MAX_STEPS_IN_FUNCTION);
    require(xSell.length <= MAX_STEPS_IN_FUNCTION);
    require(tokenData[token].listed);

    tokenData[token].buyRateQtyStepFunction = StepFunction(xBuy, yBuy);
    tokenData[token].sellRateQtyStepFunction = StepFunction(xSell, ySell);
  }

  function setImbalanceStepFunction(
    TRC20 token,
    int[] memory xBuy,
    int[] memory yBuy,
    int[] memory xSell,
    int[] memory ySell
  )
  public
  onlyOperator
  {
    require(xBuy.length == yBuy.length);
    require(xSell.length == ySell.length);
    require(xBuy.length <= MAX_STEPS_IN_FUNCTION);
    require(xSell.length <= MAX_STEPS_IN_FUNCTION);
    require(tokenData[token].listed);

    tokenData[token].buyRateImbalanceStepFunction = StepFunction(xBuy, yBuy);
    tokenData[token].sellRateImbalanceStepFunction = StepFunction(xSell, ySell);
  }

  function setValidRateDurationInBlocks(uint duration) public onlyAdmin {
    validRateDurationInBlocks = duration;
  }

  function enableTokenTrade(TRC20 token) public onlyAdmin {
    require(tokenData[token].listed);
    require(tokenControlInfo[token].minimalRecordResolution != 0);
    tokenData[token].enabled = true;
  }

  function disableTokenTrade(TRC20 token) public onlyAlerter {
    require(tokenData[token].listed);
    tokenData[token].enabled = false;
  }

  function setReserveAddress(address reserve) public onlyAdmin {
    reserveContract = reserve;
  }

  function recordImbalance(
    TRC20 token,
    int buyAmount,
    uint rateUpdateBlock,
    uint currentBlock
  )
  public
  {
    require(msg.sender == reserveContract);

    if (rateUpdateBlock == 0) rateUpdateBlock = getRateUpdateBlock(token);

    return addImbalance(token, buyAmount, rateUpdateBlock, currentBlock);
  }

  /* solhint-disable function-max-lines */
  function getRate(TRC20 token, uint currentBlockNumber, bool buy, uint qty) public view returns(uint) {
    // check if trade is enabled
    if (!tokenData[token].enabled) return 0;
    if (tokenControlInfo[token].minimalRecordResolution == 0) return 0; // token control info not set

    uint updateRateBlock = tokenData[token].lastUpdatedBlock;
    if (currentBlockNumber >= updateRateBlock + validRateDurationInBlocks) return 0; // rate is expired
    // check imbalance
    int totalImbalance;
    int blockImbalance;
    (totalImbalance, blockImbalance) = getImbalance(token, updateRateBlock, currentBlockNumber);

    // calculate actual rate
    int imbalanceQty;
    int extraBps;
    uint rate;

    if (buy) {
      // start with base rate
      rate = tokenData[token].baseBuyRate;

      // compute token qty
      qty = getTokenQty(token, rate, qty);
      imbalanceQty = int(qty);
      totalImbalance += imbalanceQty;

      // add qty overhead
      extraBps = executeStepFunction(tokenData[token].buyRateQtyStepFunction, int(qty));
      rate = addBps(rate, extraBps);

      // add imbalance overhead
      extraBps = executeStepFunction(tokenData[token].buyRateImbalanceStepFunction, totalImbalance);
      rate = addBps(rate, extraBps);
    } else {
      // start with base rate
      rate = tokenData[token].baseSellRate;

      // compute token qty
      imbalanceQty = -1 * int(qty);
      totalImbalance += imbalanceQty;

      // add qty overhead
      extraBps = executeStepFunction(tokenData[token].sellRateQtyStepFunction, int(qty));
      rate = addBps(rate, extraBps);

      // add imbalance overhead
      extraBps = executeStepFunction(tokenData[token].sellRateImbalanceStepFunction, totalImbalance);
      rate = addBps(rate, extraBps);
    }

    if (abs(totalImbalance) >= getMaxTotalImbalance(token)) return 0;
    if (abs(blockImbalance + imbalanceQty) >= getMaxPerBlockImbalance(token)) return 0;

    return rate;
  }
  /* solhint-enable function-max-lines */

  function getBasicRate(TRC20 token, bool buy) public view returns(uint) {
    if (buy)
      return tokenData[token].baseBuyRate;
    else
      return tokenData[token].baseSellRate;
  }

  function getTokenBasicData(TRC20 token) public view returns(bool, bool) {
    return (tokenData[token].listed, tokenData[token].enabled);
  }

  /* solhint-disable code-complexity */
  function getStepFunctionData(TRC20 token, uint command, uint param) public view returns(int) {
    if (command == 0) return int(tokenData[token].buyRateQtyStepFunction.x.length);
    if (command == 1) return tokenData[token].buyRateQtyStepFunction.x[param];
    if (command == 2) return int(tokenData[token].buyRateQtyStepFunction.y.length);
    if (command == 3) return tokenData[token].buyRateQtyStepFunction.y[param];

    if (command == 4) return int(tokenData[token].sellRateQtyStepFunction.x.length);
    if (command == 5) return tokenData[token].sellRateQtyStepFunction.x[param];
    if (command == 6) return int(tokenData[token].sellRateQtyStepFunction.y.length);
    if (command == 7) return tokenData[token].sellRateQtyStepFunction.y[param];

    if (command == 8) return int(tokenData[token].buyRateImbalanceStepFunction.x.length);
    if (command == 9) return tokenData[token].buyRateImbalanceStepFunction.x[param];
    if (command == 10) return int(tokenData[token].buyRateImbalanceStepFunction.y.length);
    if (command == 11) return tokenData[token].buyRateImbalanceStepFunction.y[param];

    if (command == 12) return int(tokenData[token].sellRateImbalanceStepFunction.x.length);
    if (command == 13) return tokenData[token].sellRateImbalanceStepFunction.x[param];
    if (command == 14) return int(tokenData[token].sellRateImbalanceStepFunction.y.length);
    if (command == 15) return tokenData[token].sellRateImbalanceStepFunction.y[param];

    revert();
  }
  /* solhint-enable code-complexity */

  function getRateUpdateBlock(TRC20 token) public view returns(uint) {
    require(tokenData[token].listed);
    return tokenData[token].lastUpdatedBlock;
  }

  function getListedTokensAtIndex(uint id) public view returns(TRC20) {
    require(id < listedTokens.length);
    return listedTokens[id];
  }

  function getListedTokens() public view returns(TRC20[] memory) {
    return listedTokens;
  }

  function getNumListedTokens() public view returns(uint) {
    return listedTokens.length;
  }

  function getTokenQty(TRC20 token, uint tomoQty, uint rate) internal view returns(uint) {
    uint dstDecimals = getDecimals(token);
    uint srcDecimals = TOMO_DECIMALS;

    return calcDstQty(tomoQty, srcDecimals, dstDecimals, rate);
  }

  function executeStepFunction(StepFunction memory f, int x) internal pure returns(int) {
    uint len = f.y.length;
    for (uint ind = 0; ind < len; ind++) {
      if (x <= f.x[ind]) return f.y[ind];
    }

    return f.y[len-1];
  }

  function addBps(uint rate, int bps) internal pure returns(uint) {
    require(rate <= MAX_RATE);
    require(bps >= MIN_BPS_ADJUSTMENT);
    require(bps <= MAX_BPS_ADJUSTMENT);

    uint maxBps = 100 * 100;
    return (rate * uint(int(maxBps) + bps)) / maxBps;
  }

  function abs(int x) internal pure returns(uint) {
    if (x < 0)
      return uint(-1 * x);
    else
      return uint(x);
    }
}
