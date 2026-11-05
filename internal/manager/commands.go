package manager

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

func runUpdateCommand(args []string) int {
	flags := flag.NewFlagSet("update", flag.ContinueOnError)
	retry := flags.Bool("retry", false, "Игнорировать период ожидания автоматического обновления того же неудачного кандидата")
	recoverOnly := flags.Bool("recover-only", false, "Только восстановить незавершённое обновление")
	prepareDir := flags.String("prepare-only", "", "Подготовить кандидата развёртывания, не переключая активную конфигурацию")
	prepared := flags.String("prepared", "", "Применить уже предварительно проверенный снимок кандидата")
	restore := flags.String("restore-snapshot", "", "Восстановить снимок файлов до развёртывания, восстановление службы выполняет процесс публикации")
	check := flags.String("check-snapshot", "", "Проверить перед установкой, что активные файлы всё ещё соответствуют снимку восстановления")
	verify := flags.String("verify-snapshot", "", "Восстановить выбор стратегии и проверить восстановленную службу и исходную доступность")
	sourceDir := flags.String("source-dir", "", "Каталог производственной конфигурации")
	packageRoot := flags.String("runtime-dir", "", "Каталог скриптов этой публикации")
	envFile := flags.String("env-file", "", "Файл окружения предварительной проверки")
	kernel := flags.String("kernel", "", "Абсолютный путь предварительно проверенного ядра")
	lockFD := flags.Int("lock-fd", -1, "Унаследованная блокировка обновления, удерживаемая процессом публикации")
	forceRestart := flags.Bool("force-restart", false, "Принудительно загрузить установленное ядро при публикации")
	if flags.Parse(args) != nil || flags.NArg() != 0 {
		return 1
	}
	dir, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if *sourceDir != "" {
		dir = *sourceDir
	}
	for _, path := range []string{dir, *prepareDir, *prepared, *restore, *check, *verify, *packageRoot, *envFile, *kernel} {
		if path != "" && !filepath.IsAbs(path) {
			fmt.Fprintln(os.Stderr, "Параметры публикации должны быть абсолютными путями")
			return 1
		}
	}
	modes := 0
	for _, enabled := range []bool{*recoverOnly, *prepareDir != "", *prepared != "", *restore != "", *check != "", *verify != ""} {
		if enabled {
			modes++
		}
	}
	if modes > 1 {
		fmt.Fprintln(os.Stderr, "Режимы обновления не могут комбинироваться")
		return 1
	}
	var lock *updateLock
	if *lockFD >= 0 {
		lock, err = inheritedUpdateLock(dir, *lockFD)
	} else {
		lock, err = acquireUpdateLock(dir)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		if errors.Is(err, errUpdateBusy) {
			return 3
		}
		return 1
	}
	defer lock.Close()
	u := newConfigUpdater(dir, os.Stdout)
	u.envFile, u.forceRestart = *envFile, *forceRestart
	runtime := &linuxRuntime{dir: dir, packageRoot: *packageRoot, envFile: *envFile, kernel: *kernel, output: os.Stdout}
	u.runtime = runtime
	if *restore != "" {
		var before configSnapshot
		if err = readJSON(*restore, &before); err == nil {
			err = u.apply(before)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 2
		}
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	if *check != "" || *verify != "" {
		path := *check
		if *verify != "" {
			path = *verify
		}
		var before configSnapshot
		err = readJSON(path, &before)
		if err == nil && *check != "" {
			err = u.checkDeploymentSource(before)
		} else if err == nil {
			runtime.pid, err = runtime.mainPID(ctx)
			if err == nil {
				readyCtx, readyCancel := context.WithTimeout(ctx, u.readiness)
				err = runtime.Ready(readyCtx)
				readyCancel()
			}
			if err == nil {
				probeCtx, probeCancel := context.WithTimeout(ctx, u.window)
				err = runtime.RestoreSelections(probeCtx, before.Selections)
				if err == nil && before.Verified {
					err = runtime.Probe(probeCtx)
				}
				probeCancel()
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 2
		}
		return 0
	}
	if *prepareDir != "" {
		if err = u.prepareDeployment(ctx, *prepareDir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	}
	if *prepared != "" {
		u.prepared = &configSnapshot{}
		if err = readJSON(*prepared, u.prepared); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
	}
	if err = u.RecoverLocked(); err != nil {
		if u.status.Message != err.Error() {
			fmt.Fprintln(os.Stderr, err)
		}
		if *recoverOnly {
			return 2
		}
		if _, e := os.Stat(u.path("transaction.json")); !errors.Is(e, os.ErrNotExist) {
			return 2
		}
	}
	if *recoverOnly {
		return 0
	}
	if err = u.begin(updateID()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err = u.RunLocked(ctx, *retry); err != nil {
		if u.status.Message != err.Error() {
			fmt.Fprintln(os.Stderr, err)
		}
		if u.status.Result == "rolled_back" || u.status.Result == "recovery_failed" {
			return 2
		}
		return 1
	}
	return 0
}

func recoverOnStartup(dir string) {
	lock, err := acquireUpdateLock(dir)
	if errors.Is(err, errUpdateBusy) {
		return
	} // Рабочий процесс cron всё ещё является владельцем транзакции.
	if err != nil {
		log.Printf("Ошибка проверки незавершённого обновления: %v", err)
		return
	}
	defer lock.Close()
	if err = newConfigUpdater(dir, os.Stdout).RecoverLocked(); err != nil {
		log.Printf("Результат восстановления предыдущего обновления: %v", err)
	}
}

func (h *managerHandler) updateDirectory() string {
	if h.updateDir != "" {
		return h.updateDir
	}
	dir, _ := os.Getwd()
	return dir
}
func (h *managerHandler) updater(dir string) *configUpdater {
	if h.updaterFactory != nil {
		return h.updaterFactory(dir, io.Discard)
	}
	return newConfigUpdater(dir, os.Stdout)
}

func (h *managerHandler) handleUpdateStatus(w http.ResponseWriter, r *http.Request) {
	if !h.isAuthorized(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	s, err := readStatus(h.updateDirectory())
	if errors.Is(err, os.ErrNotExist) {
		h.jsonResponse(w, updateStatus{Stage: "idle", Message: "Нет задач обновления"}, 200)
		return
	}
	if err != nil {
		http.Error(w, "Ошибка чтения состояния обновления", 500)
		return
	}
	h.jsonResponse(w, s, 200)
}

func (h *managerHandler) handleReload(w http.ResponseWriter, r *http.Request) {
	if !h.isAuthorized(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	dir := h.updateDirectory()
	lock, err := acquireUpdateLock(dir)
	if err != nil {
		code := 500
		if errors.Is(err, errUpdateBusy) {
			code = 409
		}
		http.Error(w, err.Error(), code)
		return
	}
	u := h.updater(dir)
	if err = u.RecoverLocked(); err != nil {
		if _, e := os.Stat(filepath.Join(dir, ".update-state", "transaction.json")); !errors.Is(e, os.ErrNotExist) {
			lock.Close()
			http.Error(w, "Предыдущее обновление ещё не восстановлено, проверьте журнал службы", 500)
			return
		}
	}
	id := updateID()
	if err = u.begin(id); err != nil {
		lock.Close()
		http.Error(w, "Не удалось сохранить состояние обновления", 500)
		return
	}
	go func() {
		defer lock.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		if err := u.RunLocked(ctx, true); err != nil {
			log.Printf("Задача обновления %s: %v", id, err)
		}
	}()
	w.Header().Set("Cache-Control", "no-store")
	h.jsonResponse(w, map[string]string{"id": id}, http.StatusAccepted)
}