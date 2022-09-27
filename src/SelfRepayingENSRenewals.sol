// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IAlchemistV2 } from "alchemix/interfaces/IAlchemistV2.sol";
import { AlchemicTokenV2 } from "alchemix/AlchemicTokenV2.sol";
import { WETHGateway } from "alchemix/WETHGateway.sol";
import { ETHRegistrarController, BaseRegistrarImplementation } from "ens/ethregistrar/ETHRegistrarController.sol";

import { ICurveAlETHPool } from "./interfaces/ICurveAlETHPool.sol";
import { ICurveCalc } from "./interfaces/ICurveCalc.sol";
import { IGelatoOps } from "./interfaces/IGelatoOps.sol";

// We put the event in this external library to reuse them in our tests.
library Events {

    /// @notice An event which is emitted when a user subscribe for an self repaying ENS name renewals.
    ///
    /// @param subscriber The address of the user subscribed to this service.
    /// @param name The ENS name to renew.
    event Subscribed(address indexed subscriber, string indexed name);

    /// @notice An event which is emitted when a user unsubscribe to the self repaying ENS name renewal service.
    ///
    /// @param subscriber The address of the user unsubscribed from this service.
    /// @param name The ENS name to not renew anymore.
    event Unsubscribed(address indexed subscriber, string indexed name);
}

/// @title SelfRepayingENSRenewals
/// @author Wary
contract SelfRepayingENSRenewals {

    /// @notice The ENS name renewal duration in seconds.
    uint256 constant public renewalDuration = 365 days;

    /// @notice The Alchemix WETHGateway contract.
    WETHGateway immutable wethGateway;

    /// @notice The Alchemix alETH alchemistV2 contract.
    IAlchemistV2 immutable alchemist;

    /// @notice The Alchemix alETH AlchemicTokenV2 contract.
    AlchemicTokenV2 immutable alETH;

    /// @notice The alETH + ETH Curve Pool contract.
    ICurveAlETHPool immutable alETHPool;

    /// @notice The CurveCalc contract.
    ICurveCalc immutable curveCalc;

    /// @notice The ENS ETHRegistrarController (i.e. .eth controller) contract.
    ETHRegistrarController immutable controller;

    /// @notice The ENS BaseRegistrarImplementation (i.e. .eth registrar) contract.
    BaseRegistrarImplementation immutable registrar;

    /// @notice The Gelato contract.
    address payable public immutable gelato;

    /// @notice The Gelato Ops contract.
    IGelatoOps immutable gelatoOps;

    /// @notice The Gelato address for ETH.
    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice An error used to indicate that an action could not be completed because of an illegal argument was passed to the function.
    error IllegalArgument();

    /// @notice An error used to indicate that a caller is not authorized to perform an action.
    error Unauthorized();

    /// @notice An error used to indicate that a transfer failed.
    error FailedTransfer();

    /// @notice Initialize the contract.
    ///
    /// @dev We annotate it payable to make it cheaper. Do not send ETH.
    constructor(
            IAlchemistV2 _alchemist,
            WETHGateway _wethGateway,
            ICurveAlETHPool _alETHPool,
            ICurveCalc _curveCalc,
            ETHRegistrarController _controller,
            BaseRegistrarImplementation _registrar,
            IGelatoOps _gelatoOps
    ) payable {
        alchemist = _alchemist;
        wethGateway = _wethGateway;
        alETHPool = _alETHPool;
        curveCalc = _curveCalc;
        controller = _controller;
        registrar = _registrar;
        gelatoOps = _gelatoOps;

        alETH = AlchemicTokenV2(alchemist.debtToken());
        gelato = _gelatoOps.gelato();

        // Approve the `alETHPool` Curve Pool to transfer an (almost) unlimited amount of `alETH` tokens.
        alETH.approve(address(_alETHPool), type(uint256).max);
    }

    /// @notice Subscribe to the self repaying ENS renewals service for `name`.
    ///
    /// @dev It creates a Gelato task to monitor `name`'s expiry. Fees are paid on task execution.
    ///
    /// @notice `name` must exist or this call will revert an {IllegalArgument} error.
    ///
    /// @notice Emits a {Subscribed} event.
    ///
    /// @notice **_NOTE:_** The `SelfRepayingENSRenewals` contract must have enough `AlchemistV2.mintAllowance()` to renew `name`. The can be done via the `AlchemistV2.approveMint()` method.
    /// @notice **_NOTE:_** The `msg.sender` must make sure they have enough `AlchemistV2.totalValue()` to cover `name` renewal fee.
    ///
    /// @param name The ENS name to monitor and renew.
    /// @return task The Gelato task id.
    /// @dev We return the generated task id to simplify the `this.getTaskId()` Solidity test.
    function subscribe(string memory name) external returns (bytes32 task) {
        // Check `name` exists.
        if (registrar.nameExpires(uint256(keccak256(bytes(name)))) == 0) {
            revert IllegalArgument();
        }

        // Create a gelato task to monitor `name`'s expiry and renew it.
        // We choose to pay Gelato when executing the task.
        task = gelatoOps.createTaskNoPrepayment(
            address(this),
            this.renew.selector,
            address(this),
            abi.encodeCall(this.checker, (name, msg.sender)),
            ETH
        );

        emit Events.Subscribed(msg.sender, name);
    }

    /// @notice Unsubscribe to the self repaying ENS renewals service for `name`.
    ///
    /// @notice Emits a {Unsubscribed} event.
    ///
    /// @notice **_NOTE:_** The `subscriber` (i.e. caller) can only unsubscribe from one of their renewals.
    ///
    /// @param name The ENS name to not monitor anymore.
    function unsubscribe(string memory name) external {
        // Get the Gelato task id.
        // This way is cheaper than using a mapping from subscriber`s address to taskId but returns a random value if the caller did not subscribe for `name`.
        // The taskId is checked by Gelato in the `cancelTask` below.
        bytes32 taskId = getTaskId(msg.sender, name);

        // Cancel the Gelato task if it exists or reverts.
        gelatoOps.cancelTask(taskId);

        emit Events.Unsubscribed(msg.sender, name);
    }

    /// @notice Check if `name` should be renewed.
    ///
    /// @dev This is a Gelato resolver function. It is called by their network to know when and how to execute the renew task.
    ///
    /// @param name The ENS name whose expiry is checked.
    /// @param subscriber The address of the subscriber.
    ///
    /// @return canExec The bool is true when `name` is expired.
    /// @dev It tells Gelato when to execute the task (i.e. when it is true).
    /// @return execPayload The abi encoded call to execute.
    /// @dev It tells Gelato how to execute the task. We use this view function to prepare all the possible data for free and make the renewal cheaper.
    function checker(string memory name, address subscriber) external view returns (bool canExec, bytes memory execPayload) {
        // Check `name` expiry.
        if (registrar.nameExpires(uint256(keccak256(bytes(name)))) > block.timestamp) {
            // Log the reason.
            return (false, bytes(string.concat(name, " is not expired yet.")));
        }
        // `name` is expired.
        // Get `name` rent price.
        uint256 namePrice = controller.rentPrice(name, renewalDuration);
        // Get the gelato fee in ETH.
        (uint256 gelatoFee, ) = gelatoOps.getFeeDetails();
        // The amount of ETH needed to pay the ENS renewal using Gelato.
        uint256 neededETH = namePrice + gelatoFee;

        // ⚠️ Curve alETH-ETH pool, the biggest alETH pool, makes it difficult and expensive to get an EXACT ETH amount back so we must use `curveCalc.get_dx()` outside of a transaction.
        // Get an estimate of the amount of debt (i.e. alETH) to mint from the Curve Pool by asking the CurveCalc contract.
        uint256 alETHToMint = _getAlETHToMint(neededETH);

        // Return the Gelato task payload to execute. It must call `this.renew(name, subscriber)`.
        canExec = true;
        execPayload = abi.encodeCall(
            this.renew,
            (
                name,
                subscriber,
                neededETH,
                alETHToMint
            )
        );
    }

    /// @notice Renew `name` by minting new debt from `subscriber`'s Alchemix account.
    ///
    /// @notice **_NOTE:_** This function can only be called by a Gelato Executor.
    ///
    /// @notice **_NOTE:_** When renewing, the `SelfRepayingENSRenewals` contract must have **mintAllowance()** to mint new alETH debt tokens on behalf of **subscriber** to cover **name** renewal and the Gelato fee costs. This can be done via the `AlchemistV2.approveMint()` method.
    ///
    /// @dev We annotate it payable to make it cheaper. Do not send ETH.
    ///
    /// @param name The ENS name to renew.
    /// @param subscriber The address of the subscriber.
    /// @param neededETH The ETH minimum amount needed to pay the renewal and gelato fees.
    /// @param alETHToMint The amount of alETH debt to mint from `subscriber`'s account.
    function renew(
        string calldata name,
        address subscriber,
        uint256 neededETH,
        uint256 alETHToMint
    ) external payable {
        // Only the Gelato Ops contract can call this function.
        if (msg.sender != address(gelatoOps)) {
            revert Unauthorized();
        }

        // Mint `alETHToMint` of alETH (i.e. debt token) from `subscriber`'s Alchemix account.
        // TODO: Withdraw collateral if there isn't enough available debt.
        alchemist.mintFrom(subscriber, alETHToMint, address(this));
        // Execute a Curve Pool exchange for `alETHToMint` amount of alETH tokens to at least `needETH` ETH.
        alETHPool.exchange(
            1, // alETH
            0, // ETH
            alETHToMint,
            neededETH
        );

        // Renew `name` for its expiry data + `renewalDuration` first.
        // This function returns the ETH surplus.
        controller.renew{value: address(this).balance}(name, renewalDuration);

        // Pay the Gelato executor with all the ETH left. No ETH will be stuck in this contract.
        // ⚠️ Gelato is currently free to use but this is future-proof.
        if (address(this).balance != 0) {
            (bool success, ) = gelato.call{value: address(this).balance}("");
            if (!success) revert FailedTransfer();
        }
    }

    /// @notice Get the Self Repaying ENS task id created by `subscriber` to renew `name`.
    ///
    /// @dev This is a helper function to get a Gelato task id.
    ///
    /// @notice **_NOTE:_** This function returns a "random" value if the task does not exists. Make sure you call it with a subscribed `subscriber` for `name`.
    ///
    /// @param subscriber The address of the task creator (i.e. subscriber).
    /// @param name The name to monitor and renew.
    /// @return The task id.
    /// @dev This is a Gelato task id.
    function getTaskId(address subscriber, string memory name) public view returns (bytes32) {
        bytes32 resolverHash = gelatoOps.getResolverHash(
            address(this),
            abi.encodeCall(this.checker, (name, subscriber))
        );
        return gelatoOps.getTaskId(
            address(this),
            address(this),
            this.renew.selector,
            false,
            ETH,
            resolverHash
        );
    }

    /// @dev Get the current alETH amount to get `neededETH` ETH amount back in from a Curve Pool exchange.
    function _getAlETHToMint(uint256 neededETH) internal view returns (uint256) {
        uint256[2] memory b = alETHPool.get_balances();
        return curveCalc.get_dx(
            2,
            [b[0], b[1], 0, 0, 0, 0, 0, 0],
            alETHPool.A(),
            alETHPool.fee(),
            [uint256(1e18), 1e18, 0, 0, 0, 0, 0, 0],
            [uint256(1), 1, 0, 0, 0, 0, 0, 0],
            false,
            1, // alETH
            0, // ETH
            neededETH + 1 // Because of Curve rounding errors
        );
    }

    /// @notice To receive ETH payments.
    ///
    /// @dev To receive ETH from alETHPool.exchange() and ETHRegistrarController.renew().
    /// @dev All other received ETH will be sent to the next Gelato executor.
    receive() external payable {}
}
