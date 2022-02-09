// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "./library/VaultStrategy.sol";

contract VeVaultV2 is OwnableUpgradeable, ReentrancyGuardUpgradeable, VaultStrategy {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    event Transfer(address indexed _from, address indexed _to, uint256 _amount);
    event Deposit(address indexed _from, uint256 _value, uint256 _locktime, uint256 _epoch);
    event Withdraw(address indexed _from, uint256 _value, uint256 _epoch);
    
    string public constant name = "Voting Escrowed MMF";
    string public constant symbol = "veMMF";
    uint8 public constant decimals = 18;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IBEP20 public constant MMF = IBEP20(0x97749c9B61F878a880DfE312d2594AE07AEd7656);
    uint public constant FIXED_DATE = 1642922029; // use a fixed date to get the amounts of days since

    // each epoch is 1 day
    mapping(address => uint) private veBalance; // userAddress => balance of VE tokens that user has
    mapping(address => uint256) public lockedAmount; // userAddress => totalLockedBalance (MMF)
    mapping(address => uint256) public lockedEnd;

    address public penaltyCollector;
    uint private _totalSupply;

    // For vault strategy
    uint256 public totalShares;
    mapping(address => uint256) private _shares;

    function initialize() external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
    }

    /* ========== External Views ========== */

    // Gets the current day
    function getCurrentEpoch() public view returns (uint) {
        uint diff = now.sub(FIXED_DATE);
        return diff / 86400;
    }

    // Is used to get a user's veMMF balance, which is set to decay as the user's lockup period expires
    function balanceOf(address _account) public view returns (uint) {
        return votingPowerUnlockTime(lockedAmount[_account], lockedEnd[_account]);
    }

    // Gets the current total supply of locked MMF tokens
    function totalSupply() public view returns (uint) {
        return _totalSupply;
    }

    // Boost given to user is (numLockedDays/4 years)
    function calculateBoostedAmount(uint _amount, uint _epoch) public pure returns (uint) {
        if (_epoch >= 1460) {
            return _amount;
        }
        return _amount.mul(_epoch).div(1460);
    }

    // Get voting power based on a future unlock date
    function votingPowerUnlockTime(uint256 _value, uint256 _unlockTime) public view returns (uint256) {
        uint256 _now = getCurrentEpoch();
        if (_unlockTime <= _now) return 0;

        // _lockedDays refers to the number of days that user's MMF is still locked for
        uint256 _lockedDays = _unlockTime.sub(_now);
        if (_lockedDays >= 1460) {
            return _value;
        }
        // We derive the voting power of the user based on however many more days they are still locked for
        return (_value * _lockedDays) / 1460;
    }

    /* ========== External Functions ========== */

    // Used to create a lock for a user to lock their MMF tokens when they have never locked before
    function createLock(uint256 _amount, uint _epoch) external {
        require(_amount >= 100 ether, "less than min amount");
        require(lockedAmount[msg.sender] == 0, "Withdraw old tokens first");
        require(_epoch >= 14, "at least 14 days");
        require(_epoch <= 1460, "at most 4 years");
        _depositFor(msg.sender, _amount, _epoch);
    }

    // Increase the amount of MMF tokens to lock
    function increaseAmount(uint256 _value) external {
        require(_value >= 100 ether, "less than min amount");
        _depositFor(msg.sender, _value, 0);
    }

    // Increase the amount of days that a user wishes to lock their tokens for
    function increaseUnlockTime(uint256 _days) external {
        require(_days >= 7, "Voting lock can be 7 days min");
        require(_days <= 1460, "Voting lock can be 4 years max");
        _depositFor(msg.sender, 0, _days);
    }

    // Allowed to withdraw only when lock expires, this means you are able to take out all locked MMF, and burn all veMMF
    function withdraw() external nonReentrant {
        uint256 _userAmount = strategyBalanceOf(totalShares, _shares[msg.sender]);
        uint256 _now = getCurrentEpoch();
        uint256 _lockedAmount = lockedAmount[msg.sender];
        uint256 _lockedEnd = lockedEnd[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        uint256 mmfHarvested = _withdrawStakingToken(_userAmount);

        require(_lockedAmount > 0, "Nothing to withdraw");
        require(_now >= _lockedEnd, "The lock didn't expire");
        lockedEnd[msg.sender] = 0;
        lockedAmount[msg.sender] = 0;
        veBalance[msg.sender] = 0;
        _totalSupply = _totalSupply.sub(_lockedAmount);
        emit Transfer(msg.sender, address(0), _userAmount);

        MMF.safeTransfer(msg.sender, _userAmount);

        emit Withdraw(msg.sender, _userAmount, _now);

        _harvest(mmfHarvested);
    }


    // Allows a user to do an emergency withdrawal of their locked MMF tokens
    // Applies a 30% penalisation fee
    function emergencyWithdraw() external nonReentrant {
        uint256 _lockedAmount = lockedAmount[msg.sender];
        uint256 _lockedEnd = lockedEnd[msg.sender];
        uint256 _now = getCurrentEpoch();
        require(_lockedAmount > 0, "Nothing to withdraw");
        uint256 _amount = _lockedAmount;
        if (_now < _lockedEnd) {
            uint256 _fee = (_amount * 30000) / 100000; // 30% fees
            _penalize(_fee);
            _amount = _amount - _fee;
        }
        lockedEnd[msg.sender] = 0;
        lockedAmount[msg.sender] = 0;
        veBalance[msg.sender] = 0;
        _totalSupply = _totalSupply.sub(_lockedAmount);
        emit Transfer(msg.sender, address(0), _lockedAmount);

        MMF.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _amount, _now);
    }

    /* ========== Internal Functions ========== */

    function _depositFor(address _addr, uint256 _value, uint256 _days) internal nonReentrant {
        uint256 _now = getCurrentEpoch();
        uint256 _amount = lockedAmount[_addr];
        uint256 _end = lockedEnd[_addr];
        uint256 _vp;
        if (_amount == 0) {
            _vp = calculateBoostedAmount(_value, _days);
            lockedAmount[_addr] = _value;
            lockedEnd[_addr] = _now.add(_days);
        } else if (_days == 0) {
            _vp = votingPowerUnlockTime(_value, _end);
            lockedAmount[_addr] = _amount.add(_value);
        } else {
            require(_value == 0, "Cannot increase amount and extend lock in the same tx");
            _vp = calculateBoostedAmount(_value, _days);
            lockedEnd[_addr] = _end.add(_days);
            require(_end.sub(_now) <= 1460, "Cannot extend lock to more than 4 years");
        }
        require(_vp > 0, "No benefit to lock");
        if (_value > 0) {
            MMF.safeTransferFrom(_addr, address(this), _value);
            _depositStrategy(_addr, _value);
        }

        veBalance[_addr] = veBalance[_addr].add(_vp);
        emit Transfer(address(0), _addr, _value);
    
        _totalSupply = _totalSupply.add(_value);
        
        emit Deposit(_addr, lockedAmount[_addr], lockedEnd[_addr], _now);   
    }

    // Strategy that deposits into masterchef so users can earn rewards even though they are locked up
    // This strategy allows auto-compounding of rewards back into the underlying masterchef
    function _depositStrategy(address _to, uint256 _amount) internal {
        uint256 _pool = balance();
        uint256 shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);

        uint256 mmfHarvested = _depositStakingToken(_amount);

        _harvest(mmfHarvested);
    }

    // Deposits MMF into masterchef while taking note of however much rewards was harvested
    function _withdrawStakingToken(uint256 amount)
        private
        returns (uint256 mmfHarvested)
    {
        uint256 before = MMF.balanceOf(address(this));
        MMF_MASTER_CHEF.withdraw(0, amount);
        mmfHarvested = MMF.balanceOf(address(this)).sub(amount).sub(before);
    }

    // Deposits MMF into masterchef while taking note of however much rewards was harvested
    function _depositStakingToken(uint256 amount)
        private
        returns (uint256 mmfHarvested)
    {
        uint256 before = MMF.balanceOf(address(this));
        MMF_MASTER_CHEF.deposit(pid, amount, address(0));
        mmfHarvested = MMF.balanceOf(address(this)).add(amount).sub(before);
    }

    // Deposits harvested amounts into the masterchef
    function _harvest(uint256 mmfAmount) private {
        if (mmfAmount > 0) {
            MMF_MASTER_CHEF.deposit(pid, mmfAmount, address(0));
        }
    }

    // We burn the penalisation fees if there's no penalty collector setup
    function _penalize(uint256 _amount) internal {
        if (penaltyCollector != address(0)) {
            MMF.safeTransfer(penaltyCollector, _amount);
        } else {
            MMF.safeTransfer(DEAD, _amount);
        }
    }
}