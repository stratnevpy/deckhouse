package docker_registry_manager

import (
	"fmt"
	"io/ioutil"
	"path"
	"time"

	registryclient "github.com/flant/docker-registry-client/registry"
	"github.com/romana/rlog"

	utils_file "github.com/flant/shell-operator/pkg/utils/file"
)

type DockerRegistryManager interface {
	WithRegistrySecretPath(string)
	WithErrorCallback(errorCb func())
	WithSuccessCallback(errorCb func())
	WithImageInfoCallback(imageInfoCb func() (string, string))
	WithImageUpdatedCallback(imageUpdatedCb func(string))
	Init() error
	Run()
}

var (
	RegistryToUrlMapping map[string]string
)

type MainRegistryManager struct {
	AntiopaImageDigest string
	AntiopaImageName   string
	AntiopaImageInfo   DockerImageInfo
	// клиент для обращений к
	DockerRegistry *registryclient.Registry
	// path to a file with dockercfg
	RegistrySecretPath string
	// счётчик ошибок обращений к registry
	ErrorCounter int
	// callback вызывается в случае ошибки
	ErrorCallback func()
	// calls when get info from registry
	SuccessCallback      func()
	ImageInfoCallback    func() (string, string)
	ImageUpdatedCallback func(string)
}

// InitRegistryManager получает имя образа по имени пода и запрашивает id этого образа.
func NewDockerRegistryManager() DockerRegistryManager {
	return &MainRegistryManager{
		ErrorCounter: 0,
	}
}

// Init loads authes from registry secret
func (rm *MainRegistryManager) Init() error {
	rlog.Infof("Load registry auths from %s dir", rm.RegistrySecretPath)

	if exists, err := utils_file.DirExists(rm.RegistrySecretPath); !exists {
		rlog.Errorf("Error accessing registry secret directory: %s, watcher is disabled now", err)
		return nil
	}

	var readErr error
	var secretBytes []byte
	secretBytes, readErr = ioutil.ReadFile(path.Join(rm.RegistrySecretPath, ".dockercfg"))
	if readErr != nil {
		secretBytes, readErr = ioutil.ReadFile(path.Join(rm.RegistrySecretPath, ".dockerconfigjson"))
		if readErr != nil {
			return fmt.Errorf("Cannot read registry secret from .dockercfg or .dockerconfigjson]: %s", readErr)
		}
	}

	err := LoadDockerRegistrySecret(secretBytes)
	if err != nil {
		return fmt.Errorf("Cannot load registry secret: %s", err)
	}

	registries := ""
	for k := range DockerCfgAuths {
		registries = registries + ", " + k
	}
	rlog.Infof("Load auths for: %s", registries)

	// FIXME: hack for minikube testing
	RegistryToUrlMapping = map[string]string{
		"localhost:5000": "http://kube-registry.kube-system.svc.cluster.local:5000",
	}

	return nil
}

// Запускает проверку каждые 10 секунд, не изменился ли id образа.
func (rm *MainRegistryManager) Run() {
	rlog.Infof("Registry manager: start")

	ticker := time.NewTicker(time.Duration(10) * time.Second)

	rm.CheckIsImageUpdated()
	for {
		select {
		case <-ticker.C:
			rm.CheckIsImageUpdated()
		}
	}
}

func (rm *MainRegistryManager) WithErrorCallback(errorCb func()) {
	rm.ErrorCallback = errorCb
}

func (rm *MainRegistryManager) WithSuccessCallback(successCb func()) {
	rm.SuccessCallback = successCb
}

func (rm *MainRegistryManager) WithImageInfoCallback(imageInfoCb func() (string, string)) {
	rm.ImageInfoCallback = imageInfoCb
}

func (rm *MainRegistryManager) WithImageUpdatedCallback(imageUpdatedCb func(string)) {
	rm.ImageUpdatedCallback = imageUpdatedCb
}

func (rm *MainRegistryManager) WithRegistrySecretPath(secretPath string) {
	rm.RegistrySecretPath = secretPath
}

// Основной метод проверки обновления образа.
// Метод запускается периодически. Вначале пытается достучаться до kube-api
// и по имени Pod-а получить имя и digest его образа. Когда digest получен, то
// обращается в registry и по имени образа смотрит, изменился ли digest. Если да,
// то отправляет новый digest в канал.
func (rm *MainRegistryManager) CheckIsImageUpdated() {
	// First phase:
	// Get image name and imageID from pod's status.
	// Api-server may be unavailable, status.imageID is updated with delay, so
	// this block is repeated until api-server returns object with non-empty imageID.
	if rm.AntiopaImageDigest == "" {
		rlog.Debugf("Registry manager: retrieve image name and id from kube-api")
		podImageName, podImageId := rm.ImageInfoCallback()
		if podImageName == "" {
			rlog.Infof("Registry manager: cannot get image name for pod. Will request kubernetes api-server again.")
			return
		}
		if podImageId == "" {
			rlog.Infof("Registry manager: image ID for pod is empty. Will request kubernetes api-server again.")
			return
		}

		var err error
		rm.AntiopaImageInfo, err = DockerParseImageName(podImageName)
		if err != nil {
			// Очень маловероятная ситуация, потому что Pod запустился, а имя образа из его спеки не парсится.
			rlog.Errorf("Registry manager: pod image name '%s' is invalid. Will try again. Error was: %v", podImageName, err)
			return
		}

		rm.AntiopaImageName = podImageName

		rm.AntiopaImageDigest, err = FindImageDigest(podImageId)
		if err != nil {
			rlog.Errorf("RegistryManager: %s", err)
			rm.ImageUpdatedCallback("NO_DIGEST_FOUND")
			return
		}
		// docker 1.11 case
		if rm.AntiopaImageDigest == "" {
			return
		}
	}

	// Second phase:
	// This phase is run only if docker image digest is available.
	// Create client to access docker registry.
	if rm.DockerRegistry == nil {
		rlog.Debugf("Registry manager: create docker registry client")
		var url, user, password string
		if info, hasInfo := DockerCfgAuths[rm.AntiopaImageInfo.Registry]; hasInfo {
			// FIXME Should we always use https here?
			if mappedUrl, hasKey := RegistryToUrlMapping[rm.AntiopaImageInfo.Registry]; hasKey {
				url = mappedUrl
			} else {
				url = fmt.Sprintf("https://%s", rm.AntiopaImageInfo.Registry)
			}
			user = info.Username
			password = info.Password
		}
		// Создать клиента для подключения к docker-registry
		// в единственном экземляре
		rm.DockerRegistry = NewDockerRegistry(url, user, password)
	}

	// Third phase:
	// If image name, image digest and registry client are available,
	// try to get new digest from registry.
	rlog.Debugf("Registry manager: checking registry for updates")
	digest, err := DockerRegistryGetImageDigest(rm.AntiopaImageInfo, rm.DockerRegistry)
	rm.SetOrCheckAntiopaImageDigest(digest, err)
}

// Сравнить запомненный digest образа с полученным из registry.
// Если отличаются — отправить полученный digest в канал.
// Если digest не был запомнен, то запомнить.
// Если была ошибка при опросе registry, то увеличить счётчик ошибок.
// Когда накопится 3 ошибки подряд, вывести ошибку и сбросить счётчик
func (rm *MainRegistryManager) SetOrCheckAntiopaImageDigest(digest string, err error) {
	// Если пришёл не валидный id или была ошибка — увеличить счётчик ошибок.
	// Сообщить в лог, когда накопится 3 ошибки подряд
	if err != nil || !IsValidImageDigest(digest) {
		rm.ErrorCallback()
		rm.ErrorCounter++
		if rm.ErrorCounter >= 3 {
			rlog.Errorf("Registry manager: registry request error: %s", err)
			rm.ErrorCounter = 0
		}
		return
	}
	// Request to the registry was successful, call SuccessCallback
	rm.ErrorCounter = 0
	rm.SuccessCallback()
	if digest != rm.AntiopaImageDigest {
		rm.ImageUpdatedCallback(digest)
	}
}
