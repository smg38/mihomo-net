package manager

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const maxProviderBytes = 64 << 20

type providerSpec struct {
	kind, name, path string
	options          map[string]interface{}
}

func parseConfig(ctx context.Context, path string) (map[string]interface{}, error) {
	cmd := exec.CommandContext(ctx, "yq", "-o=json", ".", path)
	b, err := diagnosticCommandOutput(ctx, "yq разбор YAML（"+path+"）", cmd)
	if err != nil {
		return nil, err
	}
	var cfg map[string]interface{}
	if json.Unmarshal(b, &cfg) != nil || len(cfg) == 0 {
		return nil, errors.New("конфигурация должна быть непустым YAML-объектом")
	}
	return cfg, nil
}

func providers(cfg map[string]interface{}) ([]providerSpec, error) {
	var result []providerSpec
	for _, kind := range []string{"rule-providers", "proxy-providers"} {
		v := cfg[kind]
		if v == nil {
			continue
		}
		items, ok := v.(map[string]interface{})
		if !ok {
			return nil, fmt.Errorf("%s должен быть объектом", kind)
		}
		names := make([]string, 0, len(items))
		for name := range items {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			options, ok := items[name].(map[string]interface{})
			if !ok {
				return nil, fmt.Errorf("элемент %s должен быть объектом", kind)
			}
			typ, _ := options["type"].(string)
			if typ == "inline" {
				continue
			}
			if typ != "http" && typ != "file" {
				return nil, fmt.Errorf("тип %s должен быть http, file или inline", kind)
			}
			path, _ := options["path"].(string)
			if path == "" && typ == "http" {
				url, _ := options["url"].(string)
				if url == "" {
					return nil, fmt.Errorf("HTTP-источник %s не содержит URL", kind)
				}
				// Mihomo's implicit cache convention; this is an identifier, not an integrity hash.
				hash := md5.Sum([]byte(url))
				prefix := "rules"
				if kind == "proxy-providers" {
					prefix = "proxies"
				}
				path = filepath.Join(prefix, hex.EncodeToString(hash[:]))
			}
			if path == "" {
				return nil, fmt.Errorf("файловый источник %s не содержит path", kind)
			}
			result = append(result, providerSpec{kind, name, path, options})
		}
	}
	return result, nil
}

func (p providerSpec) managedPath() string {
	return filepath.Join(".update-state", "providers", digest([]byte(p.kind+"\x00"+p.name))+".data")
}

// Snapshots may restore only resource files inside the deployment boundary.
func providerPath(root, name string) (string, error) {
	if filepath.IsAbs(name) {
		var err error
		name, err = filepath.Rel(root, name)
		if err != nil {
			return "", err
		}
	}
	name = filepath.Clean(name)
	if !filepath.IsLocal(name) {
		return "", errors.New("путь provider должен находиться внутри каталога развёртывания")
	}
	parts := strings.Split(name, string(filepath.Separator))
	if name == "config.yaml" || name == "subscription.yaml" || name == "cn_cidr.txt" ||
		(strings.HasPrefix(parts[0], ".") && parts[0] != ".update-state") || parts[0] == "install.sh" || parts[0] == "release.sh" ||
		parts[0] == "mihomo-manager" || parts[0] == "mihomo" || parts[0] == "scripts" || parts[0] == "lib" || parts[0] == "systemd" || parts[0] == "ui" ||
		(parts[0] == ".update-state" && (len(parts) < 3 || parts[1] != "providers")) {
		return "", errors.New("путь provider не может перезаписывать конфигурацию, программы или метаданные транзакций")
	}
	for i := range parts {
		st, err := os.Lstat(filepath.Join(append([]string{root}, parts[:i+1]...)...))
		if errors.Is(err, os.ErrNotExist) {
			break
		}
		if err != nil {
			return "", err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("символические ссылки в путях provider запрещены")
		}
		if i == len(parts)-1 && !st.Mode().IsRegular() {
			return "", errors.New("provider должен быть обычным файлом")
		}
	}
	return name, nil
}

func readLimitedProvider(file io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(file, maxConfigSize+1))
	if err == nil && len(data) > maxConfigSize {
		err = errors.New("файл provider превышает 16 MiB")
	}
	return data, err
}

func readProvider(root, name string) ([]byte, error) {
	cache, err := readProviderCache(root, name)
	return cache.data, err
}

func writeProviders(root string, resources map[string][]byte) error {
	times := make(map[string]time.Time, len(resources))
	now := time.Now()
	for name := range resources {
		times[name] = now
	}
	return writeProviderSnapshot(root, resources, times)
}

func resourceHash(resources map[string][]byte) string {
	if len(resources) == 0 {
		return ""
	}
	b, _ := json.Marshal(resources)
	return digest(b)
}

func (r *linuxRuntime) Resources(path string) (map[string][]byte, error) {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cfg, err := parseConfig(ctx, path)
	if err != nil {
		return nil, err
	}
	items, err := providers(cfg)
	if err != nil {
		return nil, err
	}
	root := filepath.Dir(path)
	resources := make(map[string][]byte)
	total := 0
	for _, p := range items {
		name, err := providerPath(r.dir, p.path)
		if err != nil {
			return nil, err
		}
		data, err := readProvider(root, name)
		if err != nil {
			return nil, err
		}
		if len(data) == 0 {
			return nil, fmt.Errorf("кэш %s отсутствует, невозможно создать полную точку восстановления", p.kind)
		}
		total += len(data)
		if total > maxProviderBytes {
			return nil, errors.New("общий размер снимка provider превышает 64 MiB")
		}
		resources[name] = data
	}
	return resources, nil
}

// Candidate paths are owned by this updater; original declarations remain in subscription.yaml.
// HTTP/interval/header semantics are retained for the running kernel.
const providerDownloadWorkers = 4

func (r *linuxRuntime) stageProviders(ctx context.Context, dir string, fetching bool) error {
	path := filepath.Join(dir, "config.yaml")
	cfg, err := parseConfig(ctx, path)
	if err != nil {
		return err
	}
	items, err := providers(cfg)
	if err != nil || len(items) == 0 {
		return err
	}
	// Resolve every path before starting any network work.
	for _, p := range items {
		if _, err := providerPath(r.dir, p.path); err != nil {
			return err
		}
		if p.options["type"] == "http" {
			if _, err := providerInterval(p.options); err != nil {
				return fmt.Errorf("%s[%s]: %w", p.kind, p.name, err)
			}
		}
	}
	var active map[string]interface{}
	if fetching {
		active, _ = parseConfig(ctx, filepath.Join(r.dir, "config.yaml"))
	}
	activeItems, _ := providers(active)
	previous := make(map[string]providerSpec, len(activeItems))
	for _, p := range activeItems {
		previous[p.managedPath()] = p
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	runtime := *r
	if r.output != nil {
		runtime.output = &synchronizedWriter{writer: r.output}
	}
	jobs := make(chan providerSpec, len(items))
	for _, p := range items {
		jobs <- p
	}
	close(jobs)
	var workers sync.WaitGroup
	var once sync.Once
	var firstErr error
	var total atomic.Int64
	for range min(providerDownloadWorkers, len(items)) {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for p := range jobs {
				if ctx.Err() != nil {
					return
				}
				size, err := runtime.prepareProvider(ctx, dir, p, previous, fetching)
				if err == nil && total.Add(int64(size)) > maxProviderBytes {
					err = errors.New("общий размер снимка provider превышает 64 MiB")
				}
				if err != nil {
					once.Do(func() {
						firstErr = fmt.Errorf("%s[%s]: подготовка зависимости не удалась (активная конфигурация не изменена): %w", p.kind, p.name, err)
						cancel()
					})
					return
				}
			}
		}()
	}
	workers.Wait()
	if firstErr != nil {
		return firstErr
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	// Worker goroutines never mutate config maps. Publish paths only after all succeed.
	for _, p := range items {
		p.options["path"] = p.managedPath()
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, b, 0600)
}

func (r *linuxRuntime) prepareProvider(ctx context.Context, dir string, p providerSpec, previous map[string]providerSpec, fetching bool) (int, error) {
	managed := p.managedPath()
	original, err := providerPath(r.dir, p.path)
	if err != nil {
		return 0, err
	}
	var cache providerCache
	if !fetching {
		cache, err = readProviderCache(dir, managed)
		if err == nil && len(cache.data) == 0 {
			cache, err = readProviderCache(dir, original)
		}
	} else if p.options["type"] == "file" {
		cache, err = readProviderCache(r.dir, original)
	} else {
		var interval time.Duration
		interval, err = providerInterval(p.options)
		if err != nil {
			return 0, err
		}
		var cacheErr error
		if old, ok := previous[managed]; ok && sameProviderSource(old.options, p.options) {
			cache, cacheErr = readProviderCache(r.dir, old.path)
			if cacheErr == nil && len(cache.data) == 0 {
				cacheErr = errors.New("кэш пуст")
			}
		}
		url, _ := p.options["url"].(string)
		if cacheErr == nil && cache.fresh(time.Now(), interval) {
			if r.output != nil {
				fmt.Fprintf(r.output, "[кэш] %s[%s] %s（не истёк, время обновления %s）\n", p.kind, p.name, url, cache.modified.Format(time.RFC3339))
			}
		} else {
			target := filepath.Join(dir, managed)
			if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
				return 0, err
			}
			if downloadErr := r.downloadProvider(ctx, p, target); downloadErr != nil {
				// Cancellation is never a successful stale-cache fallback.
				if ctx.Err() != nil {
					return 0, errors.Join(ctx.Err(), downloadErr)
				}
				if cacheErr != nil {
					return 0, errors.Join(downloadErr, fmt.Errorf("кэш из того же источника недоступен: %w", cacheErr))
				}
				if len(cache.data) == 0 {
					return 0, downloadErr
				}
				if r.output != nil {
					fmt.Fprintf(r.output, "[кэш] %s[%s] %s（скачивание не удалось, использую устаревший кэш из того же источника, время обновления %s）\n", p.kind, p.name, url, cache.modified.Format(time.RFC3339))
				}
			} else {
				cache, err = readProviderCache(dir, managed)
			}
		}
	}
	if err == nil && len(cache.data) == 0 {
		err = errors.New("содержимое provider пусто")
	}
	if err != nil {
		return 0, err
	}
	if err = writeProviderSnapshot(dir, map[string][]byte{managed: cache.data}, map[string]time.Time{managed: cache.modified}); err != nil {
		return 0, err
	}
	return len(cache.data), nil
}

func sameProviderSource(a, b map[string]interface{}) bool {
	copyOptions := func(source map[string]interface{}) []byte {
		copy := make(map[string]interface{}, len(source))
		for k, v := range source {
			// The cache location and refresh schedule do not change its source or contents.
			if k != "path" && k != "interval" {
				copy[k] = v
			}
		}
		data, _ := json.Marshal(copy)
		return data
	}
	return string(copyOptions(a)) == string(copyOptions(b))
}

func (r *linuxRuntime) downloadProvider(ctx context.Context, p providerSpec, output string) error {
	url, _ := p.options["url"].(string)
	if url == "" {
		return errors.New("URL provider отсутствует")
	}
	var headers []string
	if h := p.options["header"]; h != nil {
		values, ok := h.(map[string]interface{})
		if !ok {
			return errors.New("provider header должен быть объектом")
		}
		for key, value := range values {
			if strings.ContainsAny(key, "\r\n:") {
				return errors.New("недопустимое имя provider header")
			}
			list, ok := value.([]interface{})
			if !ok {
				return errors.New("значение provider header должно быть массивом")
			}
			for _, raw := range list {
				v, ok := raw.(string)
				if !ok || strings.ContainsAny(v, "\r\n") {
					return errors.New("недопустимое значение provider header")
				}
				headers = append(headers, key+": "+v)
			}
		}
	}
	headerFile := output + ".headers"
	if err := atomicWrite(headerFile, []byte(strings.Join(headers, "\n")+"\n"), 0600); err != nil {
		return err
	}
	defer os.Remove(headerFile)
	cmd := exec.CommandContext(ctx, "bash", "-c", `source "$1"; load_env_file "$2"; source "$3"; http_download "$4" 90 16777216 "$5"`, "provider", filepath.Join(r.packageDir(), "lib", "env.sh"), r.environmentPath(), filepath.Join(r.packageDir(), "lib", "http.sh"), output, url)
	// Stop the entire shell/curl process group when a sibling fails or the user cancels.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.Env = append(os.Environ(), "HTTP_DOWNLOAD_HEADERS_FILE="+headerFile, "MIHOMO_SOURCE_DIR="+r.dir)
	return runDiagnosticCommand(ctx, p.kind+"["+p.name+"] скачивание", cmd, r.output)
}
