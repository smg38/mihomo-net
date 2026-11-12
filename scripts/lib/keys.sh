# ------------------------------------------------------------------------------
# Идемпотентная генерация ключей
# ------------------------------------------------------------------------------
#set -x
make_keys() {
    local name="$1"
    local uuid priv pub sid
    keys=$($MIHOMO_BIN generate reality-keypair)
    [[ $keys =~ PrivateKey:[[:space:]]*([^[:space:]]+) ]] && priv="${BASH_REMATCH[1]}"
    [[ $keys =~ PublicKey:[[:space:]]*([^[:space:]]+) ]]  && pub="${BASH_REMATCH[1]}"
    sid=$(openssl rand -hex 8)
    uuid=$("$MIHOMO_BIN" generate uuid)
    printf 'UUID_%s=%s\n'        "$name" "$uuid"
    printf 'PRIVATE_KEY_%s=%s\n' "$name" "$priv"
    printf 'PUBLIC_KEY_%s=%s\n'  "$name" "$pub"
    printf 'SHORT_ID_%s=%s\n'    "$name" "$sid"
}

if [ "$1" == "test" ]; then
    local pem uuid priv pub sid
    # pem=$(mktemp /tmp/reality.XXXXXX.pem)
    # openssl genpkey -algorithm X25519 -out "$pem" 2>/dev/null
    # priv=$(openssl pkey -in "$pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
    # pub=$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=')
    # rm -f "$pem"
    MIHOMO_BIN=".tmp/mihomo"
    keys=$($MIHOMO_BIN generate reality-keypair)
    echo $keys
    # priv=$(echo $keys | grep 'Private' | cut -d ' ' -f 2)
    # publ=$(echo $keys | grep 'Public' | cut -d ' ' -f 2)
# Извлекаем PrivateKey (всё, что идет после 'PrivateKey: ' до пробела)
if [[ $keys =~ PrivateKey:[[:space:]]*([^[:space:]]+) ]]; then
    priv="${BASH_REMATCH[1]}"
fi

# Извлекаем PublicKey (всё, что идет после 'PublicKey: ' до конца строки)
if [[ $keys =~ PublicKey:[[:space:]]*([^[:space:]]+) ]]; then
    publ="${BASH_REMATCH[1]}"
fi

    echo -e "private-key: '$priv'\npublic-key: '$publ'" 
    echo "======="
#    set
    # 1. Генерируем закрытый (private) ключ в кодировке Base64:
    #PRIV_KEY=$(openssl genpkey -algorithm x25519 -pkeyopt uclicense:false 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64)
    # PRIV_HEX=$(openssl rand -hex 32)
    # PRIV_KEY=$(echo -n "$PRIV_HEX" | xxd -r -p | base64)
    # # 2. Вычисляем из него публичный (public) ключ:
    # PUB_KEY=$(echo -n "$PRIV_KEY" | base64 -d 2>/dev/null | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
    # Выводим результат на экран:
 #   echo -e "private-key: $PRIV_KEY\npublic-key: $PUB_KEY" 
 #   echo "======="    
    make_keys "C"
fi