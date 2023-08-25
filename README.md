Fyllo Lending Contracts
=================

Installation
------------

```
git clone https://github.com/fyllofinance/fyllo-lending-contracts/
cd fyllo-lending-contracts
pnpm install # or `yarn install`
```

Setup
------------

### .env
Copy `.env` from `.env.example`
abd fill in all the variables in `.env`

### hardhat.config.ts
Modify `namedAccounts` in `hardhat.config.ts` and add networks if necessary.

Deployment
------------

```
npx hardhat deploy --network <NETWORK>
```
