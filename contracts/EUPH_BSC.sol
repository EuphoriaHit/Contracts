// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract EUPH_BSC is ERC20 {
    constructor(uint256 _initialSupply) ERC20("Euphoria token", "EUPH") {
        _mint(msg.sender, _initialSupply * (10 ** decimals()));
    }
    
    function decimals() public pure override returns(uint8) {
        return 3;
    }
}