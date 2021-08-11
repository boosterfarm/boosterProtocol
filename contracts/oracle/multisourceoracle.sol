// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/ICTokenInterface.sol";
import "../interfaces/ITokenOracle.sol";

contract MultiSourceOracle is Ownable, ITokenOracle {
    using SafeMath for uint256;

    struct PriceData {
        uint price;
        uint lastUpdate;
    }

    bool public constant isPriceOracle = true;
    mapping(address => bool) public opers;
    mapping(address => address) public priceFeeds;
    mapping(address => PriceData) public store;

    event PriceUpdate(address indexed _token, uint price);
    event PriceFeed(address indexed _token, address _feed);

    constructor() public {
        opers[msg.sender] = true;
    }

    function setPriceOperator(address _oper, bool _enable) public onlyOwner {
        opers[_oper] = _enable;
    }
    
    function setFeeds(address[] memory _tokens, address[] memory _feeds) public onlyOwner {
        require(_tokens.length == _feeds.length, 'bad token length');
        for (uint idx = 0; idx < _tokens.length; idx++) {
            address token0 = _tokens[idx];
            address feed = _feeds[idx];
            priceFeeds[token0] = feed;

            emit PriceFeed(token0, feed);
            if(feed != address(0)) {
                require(ITokenOracle(feed).getPrice(token0) > 0, 'token no price');
            }
        }
    }

    /// @dev Set the prices of the token token pairs. Must be called by the oper.
    // price (scaled by 1e18).
    function setPrices(
        address[] memory tokens,
        uint[] memory prices
    ) external {
        require(opers[msg.sender], 'only oper');
        require(tokens.length == prices.length, 'bad token length');
        for (uint idx = 0; idx < tokens.length; idx++) {
            address token0 = tokens[idx];
            uint price = prices[idx];
            store[token0] = PriceData({price: price, lastUpdate: now});
            emit PriceUpdate(token0, price);
        }
    }

    /**
      * @notice Get the underlying price of a token asset
      * @param _token The _token to get the price of
      * @return The underlying asset price mantissa (scaled by 1e8).
      *  Zero means the price is unavailable.
      */
    function getPrice(address _token) public override view returns (int) {
        address feed = priceFeeds[_token];
        if(feed != address(0)) {
            return ITokenOracle(feed).getPrice(_token);
        }
        require(int(store[_token].price) >= 0, 'price to lower');
        return int(store[_token].price);
    }


    /**
      * @notice Get the underlying price of a cToken asset
      * @param cToken The cToken to get the underlying price of
      * @return The underlying asset price mantissa (scaled by 1e18).
      *  Zero means the price is unavailable.
      */
    function getUnderlyingPrice(address cToken) external view returns (uint) {
        address token = ICTokenInterface(cToken).underlying();
        int price = getPrice(token);
        require(price >= 0, 'price to lower');
        return uint(price).mul(uint(1e18).div(1e8));
    }
}