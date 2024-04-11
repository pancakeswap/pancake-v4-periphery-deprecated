// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC721Enumerable, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC721Permit} from "../interfaces/IERC721Permit.sol";

/// @title ERC721 with permit
/// @notice Nonfungible tokens that support an approve via signature, i.e. permit
abstract contract ERC721Permit is ERC721Enumerable, IERC721Permit {
    /// @dev Gets the current nonce for a token ID and then increments it, returning the original value
    function _getAndIncrementNonce(uint256 tokenId) internal virtual returns (uint256);

    /// @dev The hash of the name used in the permit signature verification
    bytes32 private immutable nameHash;

    /// @dev The hash of the version string used in the permit signature verification
    bytes32 private immutable versionHash;

    /// @notice Computes the nameHash and versionHash
    constructor(string memory name_, string memory symbol_, string memory version_) ERC721(name_, symbol_) {
        nameHash = keccak256(bytes(name_));
        versionHash = keccak256(bytes(version_));
    }

    /// @inheritdoc IERC721Permit
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return ERC721PermitLib.calculateDomainSeparator(nameHash, versionHash);
    }

    /// @inheritdoc IERC721Permit
    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_TYPEHASH =
        0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @inheritdoc IERC721Permit
    function permit(address spender, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        override
    {
        ERC721PermitLib.verifySignature(
            DOMAIN_SEPARATOR(),
            PERMIT_TYPEHASH,
            _getAndIncrementNonce(tokenId),
            ownerOf(tokenId),
            spender,
            tokenId,
            deadline,
            v,
            r,
            s
        );
        _approve(spender, tokenId);
    }
}

library ERC721PermitLib {
    function calculateDomainSeparator(bytes32 nameHash, bytes32 versionHash) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                /// @dev keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                nameHash,
                versionHash,
                block.chainid,
                address(this)
            )
        );
    }

    function verifySignature(
        bytes32 DOMAIN_SEPARATOR,
        bytes32 PERMIT_TYPEHASH,
        uint256 nonce,
        address owner,
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view {
        if (block.timestamp > deadline) {
            revert IERC721Permit.PermitExpired();
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN_SEPARATOR, keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
        if (spender == owner) {
            revert IERC721Permit.ApproveToOneself();
        }

        if (Address.isContract(owner)) {
            /// @dev cast 4 isValidSignature(bytes32,bytes) == 0x1626ba7e
            if (IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e) {
                revert IERC721Permit.Unauthorized();
            }
        } else {
            address recoveredAddress = ecrecover(digest, v, r, s);
            if (recoveredAddress == address(0)) {
                revert IERC721Permit.InvalidSignature();
            }
            if (recoveredAddress != owner) {
                revert IERC721Permit.Unauthorized();
            }
        }
    }
}
