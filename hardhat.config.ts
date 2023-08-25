import "dotenv/config";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-contract-sizer";
import "hardhat-preprocessor";
import "hardhat-deploy";
import "hardhat-contract-sizer";
import "hardhat-storage-layout-json";
import "./tasks";
import fs from "fs";

const config: HardhatUserConfig = {
  namedAccounts: {
    deployer: 0,
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: false,
    disambiguatePaths: false,
  },
  paths: {
    artifacts: "./artifacts",
    sources: "./contracts",
    cache: "./cache_hardhat",
    newStorageLayoutPath: "./storage_layout",
  },
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      {
        version: "0.5.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  networks: {
    hardhat: {},
    base: {
      url: process.env.BASE_RPC_URL,
      chainId: 8453,
      accounts: [process.env.PRIVATE_KEY as string],
    },
  },
  etherscan: {
    apiKey: {
      base: process.env.BASE_API_KEY ?? "",
    },
  },
  preprocess: {
    eachLine: (hre: any) => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          getRemappings().forEach(([find, replace]) => {
            // this matches all occurrences not just the start of import which could be a problem
            if (line.match(find)) {
              line = line.replace(find, replace);
            }
          });
        }
        return line;
      },
    }),
  },
};
function getRemappings() {
  return fs
    .readFileSync("remappings.txt", "utf8")
    .split("\n")
    .filter(Boolean) // remove empty lines
    .map((line) => line.trim().split("="));
}

export default config;
