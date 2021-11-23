# Test Smart Contracts
# Addresses
## Current test addresses of contracts
NOTE: Since the addresses are test addresses, they will be updated from time to time.
- EUPH_BSC 0x74b53e75063d36248060a8D30CFe2Ea9D7913013
- BUSD 0xbA82930cc38bE1B3cf8F106cBAf14717e7f3E69B
- IDO 0xCafDDB382E5CBAe3C93b114b18cce73dC860E00D  

The owner of all contracts is this address '0X1C9C5D82E8B109533E429E5F4DA09D64E673E0ED`

# Documentation (will be updated regularly)
## IDO.sol
### Methods:
NB! IF THE METHOD IS PRECEDED BY *, THEN IT CAN ONLY BE CALLED BY THE OWNER OF THE CONTRACT

- *initialize() - Called only once and used to initialize the contract
- 'buyTokens(uint256 busdAmount)` - The method accepts the number of BUSD tokens in full accuracy and issues back to the sender of the transaction EUPH tokens. The decimals of the BUSD token are 18. To throw 1 full-fledged BUSD token, you will need to throw 1000000000000000000 (1 and 18 zeros) into the arguments. The price of one EUPH token is 0.0009 BUSD
- *withdrawteamshare() - Releases and outputs tokens temporarily blocked for the Team in a specific address
- *withdrawmarketingshare() - Releases and outputs temporarily blocked tokens for Marketing in a specific address
- *withdrawreserveshare() - Releases and outputs tokens blocked for Reserve for a while in a specific address
- *pausecontract() - Puts the contract on pause
- *unpausecontract() - Removes the contract from pause
- *changePrice(uint256 newEuphPrice) - Changes the price of 1 EUPH token per BUSD. It is necessary to enter the value in the argument exactly
- *transfertokenstocontract(uint256 amount) - Makes it possible to throw a certain number of EUPH tokens on the IDO contract
- *withdrawbusd() - Outputs all currently accumulated BUSD tokens to the owner's address  
- *finalize() - Completes the contract and transfers all currently accumulated BUSD tokens to the owner's address

### Addresses
#### IDO Contract, while initialization process, temporarily blocks specific amount of tokens for the following shares:
Format: Address - Share (Precentage from total supply, block duration)  
- 0x2aAC387f76ed505A0F72216C885aE3cDEA003B3F - TEAM (15%, 6 Months)
- 0xCE98892a5Ca6A9509d18a5920Fa57Dfdf8baE19D - MARKETING (10%, 6 Months)
- 0xad7f22d20cd54C9243041C14f224FC13477EEDaB - RESERVE (20%, 12 Months)
- IDO address - PUBLIC (2%, ---)


The last update: 23nd of November 2021
