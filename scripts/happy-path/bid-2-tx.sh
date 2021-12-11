set -eu
thisDir=$(dirname "$0")
baseDir=$thisDir/../

DATUM_PREFIX=${DATUM_PREFIX:-0}

$baseDir/core/outbid-tx.sh \
  $(cat ~/$BLOCKCHAIN_PREFIX/buyer1.addr) \
  ~/$BLOCKCHAIN_PREFIX/buyer1.skey \
  d6cfdbedd242056674c0e51ead01785497e3a48afbbb146dc72ee1e2.123456 \
  $baseDir/$BLOCKCHAIN_PREFIX/datums/$DATUM_PREFIX/bid-1.json \
  $(cat $baseDir/$BLOCKCHAIN_PREFIX/datums/$DATUM_PREFIX/bid-1-hash.txt) \
  $(cat $baseDir/$BLOCKCHAIN_PREFIX/datums/$DATUM_PREFIX/bid-2-hash.txt) \
  $baseDir/$BLOCKCHAIN_PREFIX/datums/$DATUM_PREFIX/bid-2.json \
  30000000 \
  $baseDir/$BLOCKCHAIN_PREFIX/redeemers/bid-2.json \
  $(cat ~/$BLOCKCHAIN_PREFIX/buyer.addr) \
  10000000