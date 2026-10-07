// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {Jug, VatLike} from "../../src/Jug.sol";

contract VatMock is VatLike {
    struct IlkData {
        uint256 art; // Total Normalised Debt        [wad]
        uint256 rate; // Accumulated Debt Multiplier [ray] Actual vault debt = art × rate
    }
    // Stores Ilk data for each collateral type (ilk).
    mapping(bytes32 ilk => IlkData data) private s_ilks;

    function setIlk(bytes32 _ilk, uint256 _art, uint256 _rate) external {
        IlkData storage ilk = s_ilks[_ilk];
        ilk.art = _art;
        ilk.rate = _rate;
    }

    function ilks(bytes32 _ilk) external view override returns (uint256 art, uint256 rate) {
        IlkData memory ilk = s_ilks[_ilk];
        return (ilk.art, ilk.rate);
    }

    // Accounting is deliberately omitted.
    function fold(bytes32, address, int256) external override {}
}

contract JugUnitTest is Test {
    // A ray stores 27 decimal places: 1e27 represents 1.0, and 2e27 represents 2.0.
    uint256 internal constant RAY = 1e27;
    bytes32 internal constant ILK = "ETH-A";

    Jug internal jug;
    VatMock internal vat;

    function setUp() public {        
        vat = new VatMock();
        jug = new Jug(address(vat));
        jug.init(ILK);
    }

    // newRate = previousRate * ((base + duty) / RAY)^elapsedSeconds.
    // The 10% per-second examples below are deliberately large for easy arithmetic.
    function test_DripWithElapsedTime() public {
        // Set duty to 1.1
        jug.file(ILK, "duty", 11e26);
        // Set base to 1.0
        jug.file("base", RAY);
        // Set previous rate to 2.0
        vat.setIlk(ILK, 0, 2 * RAY);
        // Move the time ahed of 9 seconds
        vm.warp(block.timestamp + 9);

        // elapsedSeconds = block.timestamp - rho = 10 - 1 = 9
        // newRate = previousRate * ((base + duty) / RAY)^elapsedSeconds.
        // newRate = 2 × 2.1⁹ × 10²⁷ = 1.588560093162e30
        assertEq(jug.drip(ILK), 1.588560093162e30);        
    }

}
