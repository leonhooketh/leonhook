// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title RouletteTokenEth
/// @notice Фиксированный supply, без минта и без владельца. Любой ETH, пришедший на контракт
///         (исход Holder rewards хука), сразу начисляется холдерам пропорционально балансу;
///         каждый забирает своё через claim(). Пул Uniswap (PoolManager), initializer запуска
///         и адрес сжигания не участвуют — список задаётся в конструкторе и не меняется.
/// @dev    Классическая схема «magnified dividend per share» с поправками на переводы.
contract RouletteTokenEth is ERC20, ERC20Burnable {
    uint256 private constant MAGNITUDE = 2 ** 128;
    /// Пока у участвующих холдеров меньше этого, ETH копится и начисляется позже (защита от переполнения).
    uint256 public constant MIN_ELIGIBLE = 1_000 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) public excluded;
    uint256 public eligibleSupply; // сумма балансов участвующих холдеров

    uint256 public magnifiedPerShare;
    mapping(address => int256) private _corrections;
    mapping(address => uint256) public claimed;

    uint256 public pendingRewards; // пришло, пока участвующих было слишком мало
    uint256 public totalRewards; // всего начислено холдерам

    event RewardsDistributed(address indexed from, uint256 amount);
    event RewardClaimed(address indexed holder, uint256 amount);

    error NothingToClaim();
    error TransferFailed();

    constructor(string memory name_, string memory symbol_, uint256 supply, address recipient, address poolManager)
        ERC20(name_, symbol_)
    {
        excluded[recipient] = true;
        excluded[poolManager] = true;
        excluded[DEAD] = true;
        _mint(recipient, supply);
    }

    /// @notice ETH на контракт = награда холдерам. Не ревертится.
    receive() external payable {
        _distribute(msg.value);
    }

    function distribute() external payable {
        _distribute(msg.value);
    }

    /// @notice Сколько ETH холдер может забрать прямо сейчас.
    function claimable(address holder) public view returns (uint256) {
        return _accumulated(holder) - claimed[holder];
    }

    function claim() external {
        uint256 amount = claimable(msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[msg.sender] += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RewardClaimed(msg.sender, amount);
    }

    function _distribute(uint256 amount) private {
        uint256 total = amount + pendingRewards;
        if (total == 0) return;
        if (eligibleSupply < MIN_ELIGIBLE) {
            pendingRewards = total;
            return;
        }
        pendingRewards = 0;
        magnifiedPerShare += total * MAGNITUDE / eligibleSupply;
        totalRewards += total;
        emit RewardsDistributed(msg.sender, total);
    }

    function _accumulated(address holder) private view returns (uint256) {
        if (excluded[holder]) return 0;
        return uint256(int256(magnifiedPerShare * balanceOf(holder)) + _corrections[holder]) / MAGNITUDE;
    }

    /// @dev Перевод не меняет уже начисленное: поправка компенсирует изменение баланса.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        int256 shift = int256(magnifiedPerShare * value);
        if (from != address(0) && !excluded[from]) {
            _corrections[from] += shift;
            eligibleSupply -= value;
        }
        if (to != address(0) && !excluded[to]) {
            _corrections[to] -= shift;
            eligibleSupply += value;
        }
    }
}
