
// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BooDaoToken is ERC20, Ownable {
    constructor (
        ) public ERC20('Boo-Dao-Token', 'BooDao') {
    }

    mapping(address => bool) public mintWhitelist;
    
    function setMintWhitelist(address _account, bool _enabled) external onlyOwner {
        mintWhitelist[_account] = _enabled;
    }

    function mint(address _account, uint256 _amount) external {
        require(mintWhitelist[msg.sender], 'not allow');
        _mint(_account, _amount);
    }

    function burn(uint256 _amount) external {
        require(mintWhitelist[msg.sender], 'not allow');
        _burn(msg.sender, _amount);
    }
}

