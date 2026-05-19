# Відтворення Security-сценаріїв

Цей файл описує, як відтворити 10 security- і policy-сценаріїв для цього репозиторію.

Для сценаріїв, які навмисно змінюють файли в репозиторії, краще працювати в тимчасовій гілці:

```bash
git switch -c demo/security-scenarios
```

## Передумови

Встанови локальні інструменти, які використовуються в CI:

```bash
go install github.com/zricethezav/gitleaks/v8@latest
go install github.com/securego/gosec/v2/cmd/gosec@latest
go install github.com/sqlc-dev/sqlc/cmd/sqlc@v1.30.0
```

Підготуй Kubernetes-середовище для сценаріїв із Kyverno:

```bash
open -a Docker
make minikube-up
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
make kyverno-install || true
make kyverno-policies-apply
kubectl get pods -n kyverno
kubectl get cpol
```

Якщо `make kyverno-install` повідомляє про `server-side apply conflicts`, бо Kyverno вже встановлений у кластері, можна продовжувати, якщо pod'и в namespace `kyverno` мають статус `Running`, а політики показують `READY=True`.

## 1. Внесення секрету в репозиторій

Мета: завалити CI job `Secrets Scan` на `gitleaks`.

Створи файл з фейковою AWS-подібною парою ключів:

```bash
cat > .env.fake <<'EOF'
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
EOF
```

Запусти ту саму команду, що й у CI:

```bash
"$(go env GOPATH)/bin/gitleaks" detect \
  --source . \
  --exit-code 1 \
  --no-banner \
  --redact
```

Щоб відтворити падіння в GitHub Actions:

```bash
git add .env.fake
git commit -m "Trigger secrets scan failure demo"
git push -u origin demo/security-scenarios
```

Очікуваний результат: job `Secrets Scan` падає на кроці `Run gitleaks`.

## 2. Додавання небезпечного патерну в код

Мета: завалити CI job `SAST` на `gosec`.

Створи тимчасовий Go-файл із `InsecureSkipVerify`:

```bash
cat > internal/platform/httputil/insecure_tls_demo.go <<'EOF'
package httputil

import "crypto/tls"

func insecureTLSConfig() *tls.Config {
	return &tls.Config{InsecureSkipVerify: true}
}
EOF
```

Запусти ту саму команду, що й у CI:

```bash
"$(go env GOPATH)/bin/gosec" \
  -severity high \
  -confidence medium \
  ./cmd/... \
  ./internal/...
```

Щоб відтворити падіння в GitHub Actions:

```bash
git add internal/platform/httputil/insecure_tls_demo.go
git commit -m "Trigger SAST failure demo"
git push
```

Очікуваний результат: job `SAST` падає на кроці `Run gosec`.

## 3. Поява HIGH або CRITICAL вразливості в контейнерному образі

Мета: завалити CI job `Build, Scan and SBOM` на `Trivy`.

Тимчасово заміни distroless runtime-образ в одному Dockerfile на старіший Debian-based образ:

```bash
sed -i '' 's#FROM gcr.io/distroless/static-debian12#FROM debian:10-slim#' deployments/docker/gateway-service.Dockerfile
```

Побудуй і проскануй локально:

```bash
docker build -f deployments/docker/gateway-service.Dockerfile -t local/gateway-service:trivy-demo .

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:0.69.3 \
  image \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  local/gateway-service:trivy-demo
```

Щоб відтворити падіння в GitHub Actions:

```bash
git add deployments/docker/gateway-service.Dockerfile
git commit -m "Trigger Trivy failure demo"
git push
```

Очікуваний результат: matrix job `Build, Scan and SBOM` для `gateway-service` падає на кроці Trivy-сканування.

## 4. Невідповідність згенерованого `sqlc`-коду стану репозиторію

Мета: завалити CI job `Test and Lint` на кроці `Verify sqlc generated code`.

Додай новий SQL-запит без коміту згенерованих файлів:

```bash
cat >> internal/inventory/repository/postgres/query.sql <<'EOF'

-- name: CountInventoryStocks :one
SELECT COUNT(*) FROM inventory_stocks;
EOF
```

Запусти ту саму команду, що й у CI:

```bash
"$(go env GOPATH)/bin/sqlc" generate
git diff --exit-code
```

Щоб відтворити падіння в GitHub Actions, закоміть лише SQL-файл і не коміть згенеровані зміни:

```bash
git add internal/inventory/repository/postgres/query.sql
git commit -m "Trigger sqlc drift demo"
git push
```

Очікуваний результат: job `Test and Lint` падає, бо `sqlc generate` змінює tracked-файли.

## 5. Верифікація підпису з некоректною keyless identity

Мета: показати падіння `cosign verify`, коли identity workflow не збігається.

Запусти:

```bash
cosign verify ghcr.io/vladfcs/golang-microservice-university-gateway-service@sha256:fcdb21c20a0fa5e2c47b13974f925dcb9373c6002b08efcdb581b53fe697ac4c \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'https://github.com/VladFCS/golang-microservice-university/.github/workflows/wrong-workflow.yml@refs/heads/main'
```

Очікуваний результат: верифікація падає, бо identity сертифіката не відповідає реальному workflow, яким образ був підписаний.

## 6. Розгортання образу з тегом `:latest`

Мета: спрацювання Kyverno-політики `disallow-latest-tag`.

Запусти:

```bash
make kyverno-demo-bad-latest
```

Очікуваний результат: admission буде відхилений політикою `disallow-latest-tag`.

## 7. Розгортання `privileged: true`

Мета: спрацювання Kyverno-політики `disallow-privileged-containers`.

Запусти:

```bash
make kyverno-demo-bad-privileged
```

Очікуваний результат: admission буде відхилений, бо в контейнері встановлено `privileged: true`.

## 8. Розгортання з `hostPath` volume

Мета: спрацювання Kyverno-політики `disallow-host-path`.

Запусти:

```bash
make kyverno-demo-bad-hostpath
```

Очікуваний результат: admission буде відхилений, бо в маніфесті оголошено `hostPath` volume.

## 9. Розгортання без `requests/limits`

Мета: спрацювання Kyverno-політики `require-requests-limits`.

Запусти:

```bash
make kyverno-demo-bad-no-resources
```

Очікуваний результат: admission буде відхилений, бо відсутні CPU/memory `requests` і `limits`.

## 10. Розгортання непідписаного або недовіреного образу

Мета: спрацювання Kyverno-політики `verify-signed-images`.

Спочатку автентифікуйся в GHCR:

```bash
docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

Запуш тимчасовий непідписаний demo-образ:

```bash
make unsigned-demo-push
```

Після цього задеплой маніфест, який посилається на цей тег:

```bash
make kyverno-demo-unsigned
```

Очікуваний результат: admission буде відхилений політикою `verify-signed-images` з повідомленням на кшталт `no signatures found`.

## Корисні команди для перевірки

Перегляд логів Kyverno admission controller:

```bash
kubectl logs -n kyverno deploy/kyverno-admission-controller | rg 'disallow-latest-tag|disallow-privileged-containers|disallow-host-path|require-requests-limits|verify-signed-images'
```

Перевірка, що політики встановлені:

```bash
kubectl get cpol
```

Перевірка, що Kyverno працює:

```bash
kubectl get pods -n kyverno
```

## Прибирання після демо

Коли завершиш перевірки, можна прибрати тимчасові зміни:

```bash
git restore .
git clean -fd
git switch -
git branch -D demo/security-scenarios
```

Використовуй `git clean -fd` лише якщо точно хочеш видалити всі untracked-файли, створені для демо.
