// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BUSD is ERC20 {
    constructor(uint256 _initialSupply) ERC20("BUSD token", "BUSD") {
        _mint(msg.sender, _initialSupply * (10 ** decimals()));
    }
}