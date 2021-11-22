// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EUPH_ETH is ERC20PresetMinterPauser, Ownable {
    constructor(uint256 initialSupply)
    ERC20PresetMinterPauser("Euphoria token", "EUPH")
    {
        _mint(msg.sender, initialSupply);
    }

    function decimals() public view virtual override returns (uint8) {
        return 3;
    }

    function changeMinter(address minter) public onlyOwner {
        if (getRoleMemberCount(MINTER_ROLE) > 1) {
            revokeRole(MINTER_ROLE, getRoleMember(MINTER_ROLE, 1));
        }
        grantRole(MINTER_ROLE, minter);
    }
}
