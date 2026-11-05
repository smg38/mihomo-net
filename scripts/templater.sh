#!/usr/bin/env bash
# templater.sh
# v 3.4.2 2026-10-27
# Автор: @smg38
set -euo pipefail

progname=${0##*/}

usage() {
    cat >&2 <<'EOF'
Usage: VAR=value templater [-e ENVFILE] [-o OUTPUT] [-c] [-s] TEMPLATE
       VAR=value templater [-e ENVFILE] [-o OUTPUT] [-c] [-s] -

Behavior:
  If TEMPLATE is 'file.j3' and no -e is given, variables are loaded
  from 'file.env' (if it exists).
  If TEMPLATE is 'file.j3' and no -o is given, output is written to
  'file.out' (extension replaced).

Options:
  -e ENVFILE  загрузить переменные из ENVFILE (можно несколько раз)
  -o OUTPUT   записать результат в OUTPUT
  -c          очистить вывод: убрать завершающие пробелы, комментарии и пустые строки
  -s          strict: ошибка на неопределённую переменную без default
  -h          справка

Filters:
  default('V'), b64encode, b64decode, upper, lower, trim, quote,
  urlencode, sha256, md5, hexdump, replace('A','B'),
  substr(N), substr(N,M), indent(N)

Loops:
  {% for VAR in LIST %}
    ...{{ VAR }}...{{ OTHER }}...
  {% endfor %}
  LIST — переменная окружения; элементы разделены пробелами,
  табами или переводами каретки (один или несколько).
  Внутри тела доступны все переменные и фильтры.

Conditions:
  {% if CONDITION %}
    ...
  {% elif CONDITION %} ... {% else %} ... {% endif %}
  Операторы: ==, !=, >, <, >=, <=, and, or, not,
  is defined, is not defined, is empty.
  Условия можно вкладывать и использовать внутри циклов.
EOF
    exit 1
}

strict=0; clean=0; outfile=""; outfile_given=0; envfile=(); envfile_given=0; template=""

while getopts ":e:o:csh" opt; do
    case $opt in
        e) envfiles+=("$OPTARG"); envfile_given=1 ;;
        o) outfile=$OPTARG; outfile_given=1 ;;
        c) clean=1 ;;
        s) strict=1 ;;
        h) usage ;;
        \?) echo "$progname: неизвестная опция -$OPTARG" >&2; usage ;;
        :)  echo "$progname: опция -$OPTARG требует аргумент" >&2; usage ;;
    esac
done
shift $((OPTIND-1))
[[ $# -eq 1 ]] || usage
template=$1

if [[ "$template" != "-" ]]; then
    dir=$(dirname -- "$template"); base=$(basename -- "$template")
    stem=${base%.*}; [[ "$stem" == "$base" ]] && stem=$base
    if (( ! envfile_given )); then
        auto_env="$dir/$stem.env"
        [[ -f "$auto_env" ]] && envfiles+=("$auto_env")
    fi
    (( ! outfile_given )) && outfile="$dir/$stem.out"
fi

for envfile in ${envfiles[@]+"${envfiles[@]}"}; do
    [[ -f "$envfile" ]] || { echo "$progname: env-файл '$envfile' не найден" >&2; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
            val=${val#"${val%%[![:space:]]*}"}
            if [[ "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}
            elif [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val=${BASH_REMATCH[1]}
                val=${val//\\n/$'\n'}; val=${val//\\t/$'\t'}
                val=${val//\\\"/\"}; val=${val//\\\\/\\}
            else
                if [[ "$val" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then val=${BASH_REMATCH[1]}
                elif [[ "$val" =~ ^([^[:space:]]+)[[:space:]]+#.*$ ]]; then val=${BASH_REMATCH[1]}; fi
                val=${val%"${val##*[![:space:]]}"}
            fi
            [[ -z "${!key-}" ]] && export "$key=$val"
        else
            echo "$progname: пропущена строка в $envfile: $line" >&2
        fi
    done < "$envfile"
done

render_tmp=""
if [[ "$template" == "-" ]]; then
    tmp=$(mktemp); trap 'rm -f "${tmp:-}" "${render_tmp:-}"' EXIT
    cat > "$tmp"; template=$tmp
elif [[ ! -f "$template" ]]; then
    echo "$progname: файл '$template' не найден" >&2; exit 1
fi

if [[ -z "$outfile" || "$outfile" == "-" ]]; then target="/dev/stdout"; else target="$outfile"; fi

if [[ "$template" != "-" && -n "$outfile" ]]; then
    t_abs=$(readlink -f -- "$template" 2>/dev/null || echo "$template")
    o_abs=$(readlink -f -- "$outfile" 2>/dev/null || echo "$outfile")
    [[ "$t_abs" == "$o_abs" ]] && { echo "$progname: отказ: шаблон и выходной файл совпадают" >&2; exit 1; }
fi

if (( strict )); then
    mapfile -t used < <(grep -oE '\{\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$template" | sed -E 's/\{\{[[:space:]]*//' | sort -u)
    missing=()
    for v in "${used[@]}"; do
        if [[ -z "${!v-}" ]]; then
            grep -qE "\{\{[[:space:]]*${v}[[:space:]]*\|.*default\(" "$template" || missing+=("$v")
        fi
    done
    (( ${#missing[@]} )) && { printf '%s: не определены переменные: %s\n' "$progname" "${missing[*]}" >&2; exit 2; }
fi

if (( clean )); then
    render_tmp=$(mktemp)
    trap 'rm -f "${tmp:-}" "${render_tmp:-}"' EXIT
    render_target=$render_tmp
else
    render_target=$target
fi

awk '
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function shellquote(s,   r, i, c) {
    r = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\047") r = r "\047\\\047\047"
        else r = r c
    }
    return "\047" r "\047"
}
function run_capture(cmd,   out, line) {
    out = ""
    if ((cmd | getline line) > 0) out = line
    while ((cmd | getline line) > 0) out = out "\n" line
    close(cmd)
    return out
}
function f_default(v, arg) { if (v == "") return unquote(arg); return v }
function f_b64encode(v) { return run_capture("printf %s " shellquote(v) " | base64 | tr -d \047\n\047") }
function f_b64decode(v) { return run_capture("printf %s " shellquote(v) " | base64 -d 2>/dev/null") }
function f_upper(v) { return toupper(v) }
function f_lower(v) { return tolower(v) }
function f_trim(v)  { return trim(v) }
function f_quote(v) { return shellquote(v) }
function f_sha256(v) { return run_capture("printf %s " shellquote(v) " | (sha256sum 2>/dev/null || shasum -a 256) | cut -d\047 \047 -f1") }
function f_md5(v)    { return run_capture("printf %s " shellquote(v) " | (md5sum 2>/dev/null || md5) | cut -d\047 \047 -f1") }
function ord(c) {
    if (!ord_init) { for (i = 0; i < 256; i++) ord_chr[sprintf("%c", i)] = i; ord_init = 1 }
    return ord_chr[c]
}
function f_hexdump(v,   i, r) {
    r = ""
    for (i = 1; i <= length(v); i++) r = r sprintf("%02x", ord(substr(v, i, 1)))
    return r
}
function f_urlencode(v,   i, c, r) {
    r = ""
    for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1)
        if (c ~ /[A-Za-z0-9._~-]/) r = r c
        else r = r "%" sprintf("%02X", ord(c))
    }
    return r
}
function f_replace(v, arg,   p, a, b) {
    p = index(arg, ",")
    if (p == 0) return v
    a = unquote(substr(arg, 1, p-1))
    b = unquote(substr(arg, p+1))
    gsub(a, b, v)
    return v
}
function f_substr(v, arg,   p, a, b) {
    p = index(arg, ",")
    if (p == 0) return substr(v, unquote(arg)+0)
    a = unquote(substr(arg, 1, p-1)) + 0
    b = unquote(substr(arg, p+1)) + 0
    return substr(v, a, b)
}
function f_indent(v, arg,   n, pad, lines, i, m, r) {
    n = unquote(arg) + 0
    pad = sprintf("%*s", n, "")
    m = split(v, lines, "\n")
    r = ""
    for (i = 1; i <= m; i++) r = r (i > 1 ? "\n" : "") pad lines[i]
    return r
}
function unquote(s) {
    s = trim(s)
    if (s ~ /^\047.*\047$/)      s = substr(s, 2, length(s)-2)
    else if (s ~ /^".*"$/)       s = substr(s, 2, length(s)-2)
    gsub(/\\\047/, "\047", s)
    gsub(/\\\\/, "\\", s)
    return s
}
function apply_filter(v, f,   name, arg, p) {
    f = trim(f)
    p = index(f, "(")
    if (p > 0) {
        name = trim(substr(f, 1, p-1))
        arg  = substr(f, p+1)
        sub(/\)[[:space:]]*$/, "", arg)
    } else { name = f; arg = "" }
    if (name == "default")   return f_default(v, arg)
    if (name == "b64encode") return f_b64encode(v)
    if (name == "b64decode") return f_b64decode(v)
    if (name == "upper")     return f_upper(v)
    if (name == "lower")     return f_lower(v)
    if (name == "trim")      return f_trim(v)
    if (name == "quote")     return f_quote(v)
    if (name == "urlencode") return f_urlencode(v)
    if (name == "sha256")    return f_sha256(v)
    if (name == "md5")       return f_md5(v)
    if (name == "hexdump")   return f_hexdump(v)
    if (name == "replace")   return f_replace(v, arg)
    if (name == "substr")    return f_substr(v, arg)
    if (name == "indent")    return f_indent(v, arg)
    return v
}
function lv_set(d, name, val) { loop_name[d] = name; loop_val[d] = val }
function lv_get(name,   i) {
    for (i = depth; i >= 1; i--)
        if (loop_name[i] == name) return loop_val[i]
    return ""
}
function lv_has(name,   i) {
    for (i = depth; i >= 1; i--)
        if (loop_name[i] == name) return 1
    return 0
}
function split_list(s,   i, c, b, n, in_word) {
    n = 0; b = ""; in_word = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\r") {
            if (in_word) { items[++n] = b; b = ""; in_word = 0 }
        } else { b = b c; in_word = 1 }
    }
    if (in_word) items[++n] = b
    return n
}
function find_ph(line,   i, d2, start, p, rest) {
    start = index(line, "{{")
    if (start == 0) { RSTART = 0; RLENGTH = 0; return 0 }
    rest = substr(line, start+2)
    d2 = 1; i = 1; p = 0
    while (i <= length(rest)) {
        if (substr(rest, i, 2) == "{{") { d2++; i += 2; continue }
        if (substr(rest, i, 2) == "}}") { d2--; if (d2 == 0) { p = i; break }; i += 2; continue }
        i++
    }
    if (p == 0) { RSTART = 0; RLENGTH = 0; return 0 }
    RSTART = start
    RLENGTH = (start + 2 + p + 1) - start
    return 1
}
function render(line,   out, pre, ph, post, body, name, rest, v, f, j, c, d2, inner, ipos, ilen) {
    out = ""
    while (find_ph(line)) {
        pre  = substr(line, 1, RSTART-1)
        ph   = substr(line, RSTART, RLENGTH)
        post = substr(line, RSTART+RLENGTH)
        body = ph
        sub(/^\{\{[[:space:]]*/, "", body)
        sub(/[[:space:]]*\}\}$/, "", body)
        while (match(body, /\{\{[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\}\}/)) {
            ipos = RSTART; ilen = RLENGTH
            inner = substr(body, ipos+2, ilen-4)
            gsub(/[[:space:]]/, "", inner)
            if (lv_has(inner)) v = lv_get(inner)
            else               v = ENVIRON[inner]
            body = substr(body, 1, ipos-1) v substr(body, ipos+ilen)
        }
        name = body
        sub(/[[:space:]]*\|.*$/, "", name)
        name = trim(name)
        if (lv_has(name)) v = lv_get(name)
        else              v = ENVIRON[name]
        rest = body
        sub(/^[^|]*/, "", rest)
        while (rest ~ /\|/) {
            sub(/^[[:space:]]*\|[[:space:]]*/, "", rest)
            d2 = 0; j = 1; f = ""
            while (j <= length(rest)) {
                c = substr(rest, j, 1)
                if (c == "(") d2++
                else if (c == ")") d2--
                if (c == "|" && d2 == 0) break
                f = f c; j++
            }
            v = apply_filter(v, trim(f))
            rest = substr(rest, j)
        }
        out = out pre v
        line = post
    }
    return out line
}

# --- условия ---
function cond_operand(tok,   t, name) {
    t = trim(tok)
    if (t ~ /^\047.*\047$/) { sub(/^\047/, "", t); sub(/\047$/, "", t); return t }
    if (t ~ /^".*"$/)       { sub(/^"/, "", t);   sub(/"$/, "", t);   return t }
    if (t == "true")  return "1"
    if (t == "false") return ""
    if (t == "empty") return ""
    if (t ~ /^-?[0-9]+(\.[0-9]+)?$/) return t
    name = t
    if (lv_has(name)) return lv_get(name)
    if (name in ENVIRON) return ENVIRON[name]
    return ""
}
function cond_is_defined(name) {
    if (lv_has(name)) return 1
    if (name in ENVIRON) return 1
    return 0
}
function find_top_op(e, op,   i, c, d, q, ol, before, after) {
    d = 0; q = ""
    ol = length(op)
    for (i = 1; i <= length(e) - ol + 1; i++) {
        c = substr(e, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "(") { d++; continue }
        if (c == ")") { d--; continue }
        if (d != 0) continue
        if (substr(e, i, ol) == op) {
            if (op ~ /^[a-z]+$/) {
                before = (i == 1) ? " " : substr(e, i-1, 1)
                after  = (i+ol > length(e)) ? " " : substr(e, i+ol, 1)
                if (before !~ /[[:space:]]/ || after !~ /[[:space:]]/) continue
            }
            return i
        }
    }
    return 0
}
function balanced_outer(e,   i, d, c, q) {
    d = 0; q = ""
    for (i = 2; i < length(e); i++) {
        c = substr(e, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "(") d++
        else if (c == ")") { d--; if (d < 0) return 0 }
    }
    return (d == 0)
}
function cond_eval(expr,   e, p, left, right, op, name, isnot, kind, r, parts, l) {
    e = trim(expr)
    if (e == "") return 0
    p = find_top_op(e, "or")
    if (p > 0) return cond_eval(substr(e,1,p-1)) || cond_eval(substr(e,p+2))
    p = find_top_op(e, "and")
    if (p > 0) return cond_eval(substr(e,1,p-1)) && cond_eval(substr(e,p+3))
    if (match(e, /^not[[:space:]]+/))
        return !cond_eval(substr(e, RLENGTH+1))
    if (e ~ /^\(.*\)$/ && balanced_outer(e))
        return cond_eval(substr(e, 2, length(e)-2))
    if (match(e, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+is[[:space:]]+(not[[:space:]]+)?(defined|empty)$/)) {
        split(e, parts, /[[:space:]]+/)
        name = parts[1]; isnot = (parts[3] == "not") ? 1 : 0
        kind = parts[length(parts)]
        if (kind == "defined") { r = cond_is_defined(name); return isnot ? !r : r }
        else                  { r = (cond_operand(name) == ""); return isnot ? !r : r }
    }
    op = ""; p = 0
    if ((p = find_top_op(e, "==")) > 0) op = "=="
    else if ((p = find_top_op(e, "!=")) > 0) op = "!="
    else if ((p = find_top_op(e, ">=")) > 0) op = ">="
    else if ((p = find_top_op(e, "<=")) > 0) op = "<="
    else if ((p = find_top_op(e, ">"))  > 0) op = ">"
    else if ((p = find_top_op(e, "<"))  > 0) op = "<"
    if (op != "") {
        left  = cond_operand(substr(e, 1, p-1))
        right = cond_operand(substr(e, p+length(op)))
        if (left ~ /^-?[0-9]+(\.[0-9]+)?$/ && right ~ /^-?[0-9]+(\.[0-9]+)?$/) {
            l = left+0
            if (op == "==") return l == right+0
            if (op == "!=") return l != right+0
            if (op == ">=") return l >= right+0
            if (op == "<=") return l <= right+0
            if (op == ">")  return l >  right+0
            if (op == "<")  return l <  right+0
        }
        if (op == "==") return left == right
        if (op == "!=") return left != right
        if (op == ">=") return left >= right
        if (op == "<=") return left <= right
        if (op == ">")  return left >  right
        if (op == "<")  return left <  right
    }
    left = cond_operand(e)
    return (left != "" && left != "0" && left != "false")
}

function tag_kind_at(line,   k, kpos, klen) {
    k = ""; kpos = 0; klen = 0
    if (match(line, /\{%[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*%\}/)) {
        k = "for"; kpos = RSTART; klen = RLENGTH
    }
    if (match(line, /\{%[[:space:]]*endfor[[:space:]]*%\}/)) {
        if (kpos == 0 || RSTART < kpos) { k = "endfor"; kpos = RSTART; klen = RLENGTH }
    }
    if (match(line, /\{%[[:space:]]*if[[:space:]]+[^%]+%\}/)) {
        if (kpos == 0 || RSTART < kpos) { k = "if"; kpos = RSTART; klen = RLENGTH }
    }
    if (match(line, /\{%[[:space:]]*elif[[:space:]]+[^%]+%\}/)) {
        if (kpos == 0 || RSTART < kpos) { k = "elif"; kpos = RSTART; klen = RLENGTH }
    }
    if (match(line, /\{%[[:space:]]*else[[:space:]]*%\}/)) {
        if (kpos == 0 || RSTART < kpos) { k = "else"; kpos = RSTART; klen = RLENGTH }
    }
    if (match(line, /\{%[[:space:]]*endif[[:space:]]*%\}/)) {
        if (kpos == 0 || RSTART < kpos) { k = "endif"; kpos = RSTART; klen = RLENGTH }
    }
    pos = kpos; len = klen
    return k
}

function cur_active(   i) {
    for (i = 1; i <= sdepth; i++) if (!active[i]) return 0
    return 1
}
# На уровне 0 — рендерим сразу; внутри блока — сохраняем СЫРОЕ.
function push_line(s) {
    if (sdepth == 0) { print render(s); return }
    ns[sdepth]++
    ln[sdepth, ns[sdepth]] = s
}

function loop_render_line(line,   expr, cond, yes, no, rest, out, ipos, ilen, epos, elen) {
    if (match(line, /\{%[[:space:]]*if[[:space:]]+[^%]+%\}/)) {
        ipos = RSTART; ilen = RLENGTH
        expr = substr(line, ipos, ilen)
        sub(/^\{%[[:space:]]*if[[:space:]]+/, "", expr)
        sub(/[[:space:]]*%\}$/, "", expr)
        cond = cond_eval(expr)
        out = substr(line, 1, ipos-1)
        rest = substr(line, ipos+ilen)
        if (match(rest, /\{%[[:space:]]*else[[:space:]]*%\}/)) {
            epos = RSTART; elen = RLENGTH
            yes = substr(rest, 1, epos-1)
            no = substr(rest, epos+elen)
            sub(/\{%[[:space:]]*endif[[:space:]]*%\}.*$/, "", no)
            out = out (cond ? yes : no)
        } else {
            sub(/\{%[[:space:]]*endif[[:space:]]*%\}.*$/, "", rest)
            if (cond) out = out rest
        }
        return render(out)
    }
    return render(line)
}
function process_line(line,   kind, tag, head, after, p, ii, forvar, listname,
                              list, cnt, bi, k, saved_n, expr, cond,
                              was_active, rendered, acc, acc_ok,
                              iter_txt, got_body, first) {
    acc = ""
    acc_ok = cur_active()
    while (line != "") {
        kind = tag_kind_at(line)
        if (sdepth > 0 && kind_sd[sdepth] == "for" && (kind == "if" || kind == "elif" || kind == "else" || kind == "endif")) {
            ns[sdepth]++
            ln[sdepth, ns[sdepth]] = line
            loop_conditional[sdepth] = 1
            break
        }
        if (kind == "") {
            if (acc_ok) acc = acc line    # СЫРОЕ
            break
        }
        head  = substr(line, 1, pos-1)
        tag   = substr(line, pos, len)
        after = substr(line, pos + len)

        if (kind == "for") {
            if (head != "" && acc_ok) acc = acc head
            gsub(/\{%[[:space:]]*for[[:space:]]+/, "", tag)
            gsub(/[[:space:]]*%\}/, "", tag)
            tag = trim(tag)
            p = 0
            for (ii = 1; ii <= length(tag) - 3; ii++)
                if (substr(tag, ii, 4) == " in ") { p = ii; break }
            if (p == 0) {
                print "templater: некорректный {% for %}: " tag > "/dev/stderr"; exit 2
            }
            forvar   = trim(substr(tag, 1, p-1))
            listname = trim(substr(tag, p+4))
            sdepth++
            kind_sd[sdepth] = "for"
            for_name[sdepth] = forvar
            for_list[sdepth] = listname
            saved_acc[sdepth] = acc
            active[sdepth] = acc_ok
            ns[sdepth] = 0
            loop_conditional[sdepth] = 0
            acc = ""
            acc_ok = cur_active()
            line = after
            continue
        }

        if (kind == "endfor") {
            if (head != "" && cur_active() && active[sdepth]) {
                ns[sdepth]++
                ln[sdepth, ns[sdepth]] = head     # СЫРОЕ
            }
            if (sdepth == 0 || kind_sd[sdepth] != "for") {
                print "templater: {% endfor %} без {% for %}" > "/dev/stderr"; exit 2
            }
            forvar = for_name[sdepth]
            listname = for_list[sdepth]
            list = lv_has(listname) ? lv_get(listname) : ENVIRON[listname]
            cnt  = split_list(list)
            saved_n = ns[sdepth]
            was_conditional = loop_conditional[sdepth]
            for (bi = 1; bi <= saved_n; bi++) saved[bi] = ln[sdepth, bi]
            was_active = active[sdepth]
            acc = saved_acc[sdepth]
            sdepth--
            if (was_active && cnt > 0) {
                got_body = ""
                for (k = 1; k <= cnt; k++) {
                    depth++
                    lv_set(depth, forvar, items[k])
                    first = 1
                    iter_txt = ""
                    for (bi = 1; bi <= saved_n; bi++) {
                        rendered = loop_render_line(saved[bi])
                        if (first) { iter_txt = rendered; first = 0 }
                        else       { iter_txt = iter_txt "\n" rendered }
                    }
                    depth--
                    if (k > 1 && (saved_n > 1 || was_conditional)) got_body = got_body "\n"
                    got_body = got_body iter_txt
                }
                if (acc != "") acc = acc "\n" got_body
                else           acc = got_body
            }
            line = after
            acc_ok = cur_active()
            continue
        }

        if (kind == "if") {
            if (head != "" && acc_ok) acc = acc head
            expr = tag
            sub(/^\{%[[:space:]]*if[[:space:]]+/, "", expr)
            sub(/[[:space:]]*%\}$/, "", expr)
            sdepth++
            kind_sd[sdepth] = "if"
            cond = cond_eval(expr)
            if_taken[sdepth] = cond
            saved_acc[sdepth] = acc
            active[sdepth] = cond
            ns[sdepth] = 0
            acc = ""
            acc_ok = cur_active()
            line = after
            continue
        }

        if (kind == "elif") {
            if (head != "" && cur_active() && active[sdepth]) {
                ns[sdepth]++
                ln[sdepth, ns[sdepth]] = head
            }
            if (sdepth == 0 || kind_sd[sdepth] != "if") {
                print "templater: {% elif %} без {% if %}" > "/dev/stderr"; exit 2
            }
            expr = tag
            sub(/^\{%[[:space:]]*elif[[:space:]]+/, "", expr)
            sub(/[[:space:]]*%\}$/, "", expr)
            if (if_taken[sdepth]) {
                active[sdepth] = 0
            } else {
                cond = cond_eval(expr)
                active[sdepth] = cond
                if (cond) if_taken[sdepth] = 1
            }
            line = after
            acc_ok = cur_active()
            continue
        }

        if (kind == "else") {
            if (head != "" && cur_active() && active[sdepth]) {
                ns[sdepth]++
                ln[sdepth, ns[sdepth]] = head
            }
            if (sdepth == 0 || kind_sd[sdepth] != "if") {
                print "templater: {% else %} без {% if %}" > "/dev/stderr"; exit 2
            }
            if (if_taken[sdepth]) active[sdepth] = 0
            else { active[sdepth] = 1; if_taken[sdepth] = 1 }
            line = after
            acc_ok = cur_active()
            continue
        }

        if (kind == "endif") {
            if (head != "" && cur_active() && active[sdepth]) {
                ns[sdepth]++
                ln[sdepth, ns[sdepth]] = head
            }
            if (sdepth == 0 || kind_sd[sdepth] != "if") {
                print "templater: {% endif %} без {% if %}" > "/dev/stderr"; exit 2
            }
            was_active = if_taken[sdepth]
            acc = saved_acc[sdepth]
            sdepth--
            if (was_active) {
                first = 1
                got_body = ""
                for (bi = 1; bi <= ns[sdepth+1]; bi++) {
                    if (first) { got_body = ln[sdepth+1, bi]; first = 0 }
                    else       { got_body = got_body "\n" ln[sdepth+1, bi] }
                }
                if (got_body != "") {
                    if (acc != "") acc = acc "\n" got_body
                    else           acc = got_body
                }
            }
            ns[sdepth+1] = 0
            if (sdepth > 0 && got_body != "") {
                ns[sdepth]++
                ln[sdepth, ns[sdepth]] = got_body
            }
            line = after
            acc_ok = cur_active()
            continue
        }
    }
    if (acc != "") push_line(acc)
}

BEGIN { sdepth = 0; depth = 0 }
{ process_line($0) }
END {
    if (sdepth > 0) {
        if (kind_sd[sdepth] == "if") print "templater: незакрытый блок {% if %}: ожидается {% endif %}" > "/dev/stderr"
        else print "templater: незакрытый блок {% for %}: ожидается {% endfor %}" > "/dev/stderr"
        exit 2
    }
}
' "$template" > "$render_target"

if (( clean )); then
    awk '
        {
            sub(/[[:space:]]+$/, "")
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
            print
        }
    ' "$render_tmp" > "$target"
fi
