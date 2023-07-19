# K2 - Open Restaking

Open restaking is a staked ETH lending protocol, a unified risk profile for slashable lending to middlewares-based network security. With K2, anyone can Ethereum slashable guarantee for their custom slashing logic Think of it like an extended security layer shared by existing Ethereum validators for innovation.

K2 replicates the economic security of staked ETH, providing a platform for other networks and protocols to add and reinforce their operational logic and decentralized trust. The protocol’s state-of-the-art ZK gadget works as a quick and simple witness endorser. 

LSTs: K2 accepts stETH, rETH, dETH, and kETH as deposits.

Native Delegation allows anyone to delegate their validators' staked ETH to K2 without changing withdrawal credentials, adding additional capital, or operating additional software or hardware. This is done through state replication of the Ethereum validator’s effective balance from the consensus layer. 

## K2 Walk Through

If you want an insight directly from the development team, have a look at the following YouTube walk through: https://youtu.be/2847ofFpBiM?si=PoAx1avuGmK3YSbX 

## K2 Architecture

<img width="852" alt="image" src="https://github.com/restaking-cloud/k2-contracts-alpha/assets/147556181/ccacf47e-1356-4767-b974-eab9970ecbb6">

Key concepts:
- Borrower (service provider):
  - Offers slashing middleware
  - Takes out slashable positions on lenders
  - Pays interest for the economic security
- Lenders
  - Validators with kETH capital
  - Deposit their capital into lending pool to earn interest payment for running software
- Middleware + Software
  - Middleware is designated verifier for reports of corruption or liveness detected by reporters
  - Reporters detect issues in software validators are running
- Reporters
  - Are known actors in reporter registry
  - Run a searching software
  - Submit liquidations to the k^2 contracts and gets paid kETH

 ## Slashable Borrow position (SBP)

For kETH lenders, its simple - deposit and accrue pro-rata kETH.

This forms the base for what can be borrowed and then a multiple is applied. Borrowing does not require collateral as kETH never transferred to borrowers - they simply take a debt position.

Utilisation ratio dictates over a duration how much base interest (b) should be paid:

Borrower will also specify:
- Max slashable amount per liveness event (s)
- Max slashable amount per corruption event (c)

Interest payment is then defined as:
i = b +  s * (s/st) + c * (c/ct)

where:
- st = max s value possible
- ct = max c value possible

Finally borrower specifies public key of the middleware that will authorise slashing and the position is opened reducing the global amount of collateral that can be borrowed.

## SBP+ Hooks (Coming soon)

SBP and other hooks will be coming to the K2 contracts. Example hooks you may have access to for an SBP:
- Slashing notification
- Liquidation notification

When processing an event, SBP creators can decide to do periphery actions including but not limited to circuit breakers, trigger governance etc. The possibilities with hooks will be unlimited and example templates will be given.
