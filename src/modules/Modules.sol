/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {Owned} from "lib/solmate/src/auth/Owned.sol";

// Inspired by Default framework keycode management of dependencies and based on the Modules pattern

// Keycode functions

/// @notice     5 byte/character identifier for the Module
/// @dev        3-5 characters from A-Z
type Keycode is bytes5;

/// @notice     7 byte identifier for the Module, including version
/// @dev        2 characters from 0-9 (a version number), followed by Keycode
type Veecode is bytes7;

error TargetNotAContract(address target_);
error InvalidVeecode(Veecode veecode_);

function toKeycode(bytes5 keycode_) pure returns (Keycode) {
    return Keycode.wrap(keycode_);
}

function fromKeycode(Keycode keycode_) pure returns (bytes5) {
    return Keycode.unwrap(keycode_);
}

// solhint-disable-next-line func-visibility
function wrapVeecode(Keycode keycode_, uint8 version_) pure returns (Veecode) {
    // Get the digits of the version
    bytes1 firstDigit = bytes1(version_ / 10 + 0x30);
    bytes1 secondDigit = bytes1((version_ % 10) + 0x30);

    // Pack everything and wrap as a Veecode
    return Veecode.wrap(bytes7(abi.encodePacked(firstDigit, secondDigit, keycode_)));
}

// solhint-disable-next-line func-visibility
function toVeecode(bytes7 veecode_) pure returns (Veecode) {
    return Veecode.wrap(veecode_);
}

// solhint-disable-next-line func-visibility
function fromVeecode(Veecode veecode_) pure returns (bytes7) {
    return Veecode.unwrap(veecode_);
}

function unwrapVeecode(Veecode veecode_) pure returns (Keycode, uint8) {
    bytes7 unwrapped = Veecode.unwrap(veecode_);

    // Get the version from the first 2 bytes
    uint8 version = (uint8(unwrapped[0]) - 0x30) * 10;
    version += uint8(unwrapped[1]) - 0x30;

    // Get the Keycode by shifting the full Veecode to the left by 2 bytes
    Keycode keycode = Keycode.wrap(bytes5(unwrapped << 16));

    return (keycode, version);
}

// solhint-disable-next-line func-visibility
function ensureContract(address target_) view {
    if (target_.code.length == 0) revert TargetNotAContract(target_);
}

// solhint-disable-next-line func-visibility
function ensureValidVeecode(Veecode veecode_) pure {
    bytes7 unwrapped = Veecode.unwrap(veecode_);
    for (uint256 i; i < 7; ) {
        bytes1 char = unwrapped[i];
        if (i < 2) {
            // First 2 characters must be the version, each character is a number 0-9
            if (char < 0x30 || char > 0x39) revert InvalidVeecode(veecode_);
        } else if (i < 5) {
            // Next 3 characters after the first 3 can be A-Z
            if (char < 0x41 || char > 0x5A) revert InvalidVeecode(veecode_);
        } else {
            // Last 2 character must be A-Z or blank
            if (char != 0x00 && (char < 0x41 || char > 0x5A)) revert InvalidVeecode(veecode_);
        }
        unchecked {
            i++;
        }
    }

    // Check that the version is not 0
    // This is because the version is by default 0 if the module is not installed
    (, uint8 moduleVersion) = unwrapVeecode(veecode_);
    if (moduleVersion == 0) revert InvalidVeecode(veecode_);
}

abstract contract WithModules is Owned {
    // ========= ERRORS ========= //
    error InvalidModuleInstall(Keycode keycode_, uint8 version_);
    error ModuleNotInstalled(Keycode keycode_, uint8 version_);
    error ModuleExecutionReverted(bytes error_);
    error ModuleAlreadySunset(Keycode keycode_);
    error ModuleSunset(Keycode keycode_);

    // ========= EVENTS ========= //

    event ModuleInstalled(
        Keycode indexed keycode_,
        uint8 indexed version_,
        address indexed address_
    );

    // ========= CONSTRUCTOR ========= //

    constructor(address owner_) Owned(owner_) {}

    // ========= MODULE MANAGEMENT ========= //

    struct ModStatus {
        uint8 latestVersion;
        bool sunset;
    }

    /// @notice Array of all modules currently installed.
    Keycode[] public modules;

    /// @notice Mapping of Veecode to Module address.
    mapping(Veecode => Module) public getModuleForVeecode;

    /// @notice Mapping of Keycode to module status information
    mapping(Keycode => ModStatus) public getModuleStatus;

    /// @notice Installs a module. Can be used to install a new module or upgrade an existing one.
    /// @dev The version of the installed module must be one greater than the latest version. If it's a new module, then the version must be 1.
    /// @dev Only one version of a module is active for creation functions at a time. Older versions continue to work for existing data.
    /// @dev If a module is currently sunset, installing a new version will remove the sunset.
    ///
    /// @dev        This function reverts if:
    /// @dev        - The caller is not the owner
    /// @dev        - The module is not a contract
    /// @dev        - The module has an invalid Veecode
    /// @dev        - The module (or other versions) is already installed
    /// @dev        - The module version is not one greater than the latest version
    function installModule(Module newModule_) external onlyOwner {
        // Validate new module is a contract, has correct parent, and has valid Keycode
        ensureContract(address(newModule_));
        Veecode veecode = newModule_.VEECODE();
        ensureValidVeecode(veecode);
        (Keycode keycode, uint8 version) = unwrapVeecode(veecode);

        // Validate that the module version is one greater than the latest version
        ModStatus storage status = getModuleStatus[keycode];
        if (version != status.latestVersion + 1) revert InvalidModuleInstall(keycode, version);

        // Store module data and remove sunset if applied
        status.latestVersion = version;
        if (status.sunset) status.sunset = false;
        getModuleForVeecode[veecode] = newModule_;

        // If the module is not already installed, add it to the list of modules
        if (version == uint8(1)) modules.push(keycode);

        // Initialize the module
        newModule_.INIT();

        emit ModuleInstalled(keycode, version, address(newModule_));
    }

    /// @notice Prevents future use of module, but functionality remains for existing users. Modules should implement functionality such that creation functions are disabled if sunset.
    /// @dev Sunset is used to disable a module type without installing a new one.
    function sunsetModule(Keycode keycode_) external onlyOwner {
        // Check that the module is installed
        if (!_moduleIsInstalled(keycode_)) revert ModuleNotInstalled(keycode_, 0);

        // Check that the module is not already sunset
        ModStatus storage status = getModuleStatus[keycode_];
        if (status.sunset) revert ModuleAlreadySunset(keycode_);

        // Set the module to sunset
        status.sunset = true;
    }

    // Decide if we need this function, i.e. do we need to set any parameters or call permissioned functions on any modules?
    // Answer: yes, e.g. when setting default values on an Auction module, like minimum duration or minimum deposit interval
    function execOnModule(
        Veecode veecode_,
        bytes memory callData_
    ) external onlyOwner returns (bytes memory) {
        address module = _getModuleIfInstalled(veecode_);
        (bool success, bytes memory returnData) = module.call(callData_);
        if (!success) revert ModuleExecutionReverted(returnData);
        return returnData;
    }

    // Need to consider the implications of not having upgradable modules and the affect of this list growing over time
    function getModules() external view returns (Keycode[] memory) {
        return modules;
    }

    // Checks whether any module is installed under the keycode
    function _moduleIsInstalled(Keycode keycode_) internal view returns (bool) {
        // Any module that has been installed will have a latest version greater than 0
        // We can check not equal here to save gas
        uint8 latestVersion = getModuleStatus[keycode_].latestVersion;
        return latestVersion != uint8(0);
    }

    function _getLatestModuleIfActive(Keycode keycode_) internal view returns (address) {
        // Check that the module is installed
        ModStatus memory status = getModuleStatus[keycode_];
        if (status.latestVersion == uint8(0)) revert ModuleNotInstalled(keycode_, 0);

        // Check that the module is not sunset
        if (status.sunset) revert ModuleSunset(keycode_);

        // Wrap into a Veecode, get module address and return
        // We don't need to check that the Veecode is valid because we already checked that the module is installed and pulled the version from the contract
        Veecode veecode = wrapVeecode(keycode_, status.latestVersion);
        return address(getModuleForVeecode[veecode]);
    }

    function _getModuleIfInstalled(
        Keycode keycode_,
        uint8 version_
    ) internal view returns (address) {
        // Check that the module is installed
        ModStatus memory status = getModuleStatus[keycode_];
        if (status.latestVersion == uint8(0)) revert ModuleNotInstalled(keycode_, 0);

        // Check that the module version is less than or equal to the latest version and greater than 0
        if (version_ > status.latestVersion || version_ == 0)
            revert ModuleNotInstalled(keycode_, version_);

        // Wrap into a Veecode, get module address and return
        // We don't need to check that the Veecode is valid because we already checked that the module is installed and pulled the version from the contract
        Veecode veecode = wrapVeecode(keycode_, version_);
        return address(getModuleForVeecode[veecode]);
    }

    function _getModuleIfInstalled(Veecode veecode_) internal view returns (address) {
        // In this case, it's simpler to check that the stored address is not zero
        Module mod = getModuleForVeecode[veecode_];
        if (address(mod) == address(0)) {
            (Keycode keycode, uint8 version) = unwrapVeecode(veecode_);
            revert ModuleNotInstalled(keycode, version);
        }
        return address(mod);
    }
}

/// @notice Modules are isolated components of a contract that can be upgraded independently.
/// @dev    Two main patterns are considered for Modules:
///         1. Directly calling modules from the parent contract to execute upgradable logic or having the option to add new sub-components to a contract
///         2. Delegate calls to modules to execute upgradable logic, similar to a proxy, but only for specific functions and being able to add new sub-components to a contract
abstract contract Module {
    error Module_OnlyParent(address caller_);
    error Module_InvalidParent();

    /// @notice The parent contract for this module.
    // TODO should we use an Owner pattern here to be able to change the parent?
    // May be useful if the parent contract needs to be replaced.
    // On the otherhand, it may be better to just deploy a new module with the new parent to reduce the governance burden.
    address public parent;

    constructor(address parent_) {
        parent = parent_;
    }

    /// @notice Modifier to restrict functions to be called only by parent module.
    modifier onlyParent() {
        if (msg.sender != parent) revert Module_OnlyParent(msg.sender);
        _;
    }

    /// @notice 7 byte, versioned identifier for the module. 2 characters from 0-9 that signify the version and 3-5 characters from A-Z.
    function VEECODE() public pure virtual returns (Veecode) {}

    /// @notice Initialization function for the module
    /// @dev    This function is called when the module is installed or upgraded by the module.
    /// @dev    MUST BE GATED BY onlyParent. Used to encompass any initialization or upgrade logic.
    function INIT() external virtual onlyParent {}
}
