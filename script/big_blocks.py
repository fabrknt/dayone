"""Turn big blocks on or off for the deploying address on HyperEVM (a signed HyperCore action).

    uv run --with hyperliquid-python-sdk python -I script/big_blocks.py on|off [--mainnet]

Reads the private key from the earlier key file (or KEY_FILE). LaunchPool's initcode does not
fit a small block (2M gas), so the deployer turns big blocks on, deploys, and turns them off.
"""
import os, sys
from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants

on = {"on": True, "off": False}[sys.argv[1]]
url = constants.MAINNET_API_URL if "--mainnet" in sys.argv else constants.TESTNET_API_URL
key = open(os.path.expanduser(os.environ.get("KEY_FILE", "the earlier key file"))).read().strip()
wallet = Account.from_key(key)
print("address", wallet.address, "api", url)
# empty metadata: this action needs none, and the SDK fails to parse testnet's spot list
ex = Exchange(wallet, url, meta={"universe": []}, spot_meta={"universe": [], "tokens": []}, perp_dexs=[""])
print(ex.use_big_blocks(on))
