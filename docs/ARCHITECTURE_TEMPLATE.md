# FastAPI + Adapter 아키텍처 — 0부터 복제하기 위한 참고 문서

이 문서는 `sample-lambda` 프로젝트의 구조를 **그대로 0에서부터 재현**할 수 있도록,
파일 단위로 무엇을 만들고 왜 그렇게 만드는지를 정리한 실행 가능한 참고 문서입니다.
AWS Lambda/SSM은 "현재 채택한 구현체"일 뿐이며, 각 단계마다 다른 기술로 대체하는 법도 함께 표기합니다.

---

## 0. 디렉토리 스켈레톤 (먼저 이 모양을 만든다)

```
my-project/
├── app/
│   ├── __init__.py
│   ├── main.py          # 1) 순수 비즈니스 로직 (FastAPI app)
│   └── config.py        # 2) 설정 로더
├── handler.py            # 3) 배포 어댑터 (Lambda 진입점)
├── pyproject.toml        # 4) 의존성 정의
├── Makefile               # 5) 빌드/배포 절차
└── .github/workflows/dev.yaml   # 6) CI/CD
```

이 6개 파일이 갖춰지면 아키텍처 복제는 끝입니다. 아래에서 각각을 순서대로 작성합니다.

---

## 1. `app/main.py` — 순수 비즈니스 로직 계층

### 규칙
- 이 파일(및 `app/` 패키지 전체)은 **"내가 어디서 실행되는지" 절대 알아서는 안 됨**
- `boto3`, `aws_lambda_powertools`, 클라우드 SDK import **금지**
- 표준 ASGI 프레임워크(FastAPI)만 사용 → 로컬 `uvicorn`과 배포 어댑터가 동일한 객체를 공유

### 템플릿
```python
from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"message": "Hello from Lambda"}
```

### 확장 규칙
- 라우트가 5~10개를 넘어가면 `app/routers/xxx.py`로 분리하고 `app.include_router()`로 등록
- 그래도 `app/main.py`는 "라우터를 모으는 조립 지점" 역할만 하고 로직을 직접 담지 않게 됨

### 다른 스택으로 대체 시
| 언어/프레임워크 | 대체 |
|---|---|
| Python | FastAPI(현재), Flask+asgiref |
| Node.js | Express, Fastify (handler는 `serverless-http`로) |
| Go | net/http, Gin (handler는 `aws-lambda-go-api-proxy`) |
| Java | Spring Boot (handler는 `aws-serverless-java-container`) |

핵심 불변 조건: **"app 객체/인스턴스 하나가 로컬 실행과 배포 실행 모두에서 동일하게 재사용된다."**

---

## 2. `app/config.py` — 설정 로더 계층

### 규칙
- 모듈을 import하는 순간(콜드스타트 시 1회) 설정을 읽어와 **dict 하나로 캐싱**
- 호출부는 항상 `config["KEY"]` 형태로만 접근 → 소스가 SSM이든 .env든 호출부 코드는 안 바뀜
- 이 파일에만 외부 설정 스토어에 대한 SDK 의존이 존재해야 함

### 템플릿 (AWS SSM 버전 — 현재 프로젝트)
```python
import os

import boto3


def _load() -> dict:
    ssm = boto3.client("ssm")
    prefix = os.environ["SSM_PREFIX"]
    response = ssm.get_parameters_by_path(Path=prefix, WithDecryption=True)
    return {p["Name"].removeprefix(prefix + "/"): p["Value"] for p in response["Parameters"]}


config = _load()
```

### 대체 구현 — 같은 인터페이스(`config: dict`)를 유지하며 소스만 교체

**.env 파일 (로컬/소규모 프로젝트)**
```python
import os
from dotenv import load_dotenv

def _load() -> dict:
    load_dotenv()
    return dict(os.environ)

config = _load()
```

**AWS Secrets Manager**
```python
import json
import os
import boto3

def _load() -> dict:
    client = boto3.client("secretsmanager")
    secret_id = os.environ["SECRET_ID"]
    response = client.get_secret_value(SecretId=secret_id)
    return json.loads(response["SecretString"])

config = _load()
```

**순수 환경변수만 (가장 단순)**
```python
import os

def _load() -> dict:
    return dict(os.environ)

config = _load()
```

핵심 불변 조건: **"`_load()`는 항상 `dict`를 반환하고, 그 외 나머지 코드는 이 함수의 내부 구현을 절대 모른다."**

---

## 3. `handler.py` — 배포 어댑터 계층

### 규칙
- 이 파일만 배포 플랫폼(Lambda)을 알고 있음
- `app/main.py`의 `app`을 import해서 플랫폼이 요구하는 형태로 감싸기만 함
- 로직 0줄, 어댑팅(wrapping) 코드만 존재

### 템플릿 (AWS Lambda — 현재 프로젝트)
```python
from mangum import Mangum

from app.main import app

handler = Mangum(app, lifespan="off")
```

### 대체 구현
| 배포 타깃 | handler.py 대체 코드 |
|---|---|
| 컨테이너/VM/ECS (서버 상시 구동) | 이 파일 자체가 필요 없음. `uvicorn app.main:app`으로 직접 실행 |
| Google Cloud Functions | `import functions_framework` + ASGI 어댑터로 감싸기 |
| Azure Functions | `azure.functions.AsgiMiddleware(app)` |
| Vercel Serverless | `from mangum import Mangum` 동일하게 사용 가능 |

핵심 불변 조건: **"배포 플랫폼을 바꿀 때 이 파일 하나만 교체하면 된다. `app/` 디렉토리는 절대 손대지 않는다."**

---

## 4. `pyproject.toml` — 의존성 정의

### 규칙
- 런타임 의존성과 dev 의존성을 명확히 분리 (`[project.dependencies]` vs `[dependency-groups].dev`)
- 런타임 의존성은 **최소한**으로 유지 (콜드스타트/패키지 크기에 직결)
- 배포 환경에 기본 포함되는 SDK(예: Lambda의 `boto3`)는 dev 그룹에만 명시하고 런타임에서 제외

### 템플릿
```toml
[project]
name = "api-server"
version = "0.1.0"
requires-python = ">=3.13"
dependencies = [
    "fastapi>=0.115.0",
    "uvicorn[standard]>=0.34.0",
    "mangum>=0.19.0",
]

[dependency-groups]
dev = [
    # boto3는 Lambda 런타임에 기본 포함. 로컬 실행 시에만 필요.
    "boto3>=1.34.0",
]
```

### 대체 구현
- AWS Lambda가 아니라면 `mangum` 제거, 대신 배포 타깃에 맞는 어댑터 라이브러리 추가
- `boto3`도 SSM/Secrets Manager를 안 쓰면 완전히 제거하고, 대신 `python-dotenv`/`hvac`/`google-cloud-secret-manager` 등으로 교체

---

## 5. `Makefile` — 빌드/배포 절차

### 규칙
- "로컬 개발 실행", "배포 아티팩트 빌드", "배포 실행"을 명령 3개로 명확히 분리
- 빌드 단계는 **항상 격리된 디렉토리에 프로덕션 의존성만 설치 → 코드 복사 → 패키징** 순서를 따름
- 이렇게 하면 dev 의존성, 로컬 캐시, 불필요한 파일이 배포 아티팩트에 섞이지 않음

### 템플릿 (AWS Lambda zip 배포 — 현재 프로젝트)
```makefile
FUNCTION_NAME ?= my-function-name

.PHONY: dev build deploy

dev:
	uvicorn app.main:app --reload

build:
	rm -rf ./_package lambda.zip
	uv export --no-dev --no-hashes -o requirements.txt
	uv pip install \
		--python-platform x86_64-unknown-linux-gnu \
		--python 3.13 \
		--no-installer-metadata \
		-r requirements.txt \
		--target ./_package
	rm requirements.txt
	cp -R ./app ./_package/app
	cp handler.py ./_package/
	cd _package && zip -r ../lambda.zip . && cd ..
	rm -rf ./_package

deploy:
	aws lambda update-function-code \
		--function-name $(FUNCTION_NAME) \
		--zip-file fileb://lambda.zip
```

### 대체 구현

**컨테이너 배포 (ECS / Cloud Run / Lambda Container Image)**
```makefile
IMAGE ?= my-app:latest

dev:
	uvicorn app.main:app --reload

build:
	docker build -t $(IMAGE) .

deploy:
	docker push $(IMAGE)
```

**Serverless Framework / Terraform 등 IaC 결합**
```makefile
build:
	# 위와 동일한 zip 패키징 절차

deploy:
	terraform apply -auto-approve
	# 또는: serverless deploy
```

핵심 불변 조건: **`dev`(로컬), `build`(아티팩트 생성), `deploy`(반영)는 항상 분리된 단계로 유지하고, CI에서도 동일한 make 타겟을 그대로 호출한다.**

---

## 6. `.github/workflows/dev.yaml` — CI/CD

### 규칙
- 수동 트리거(`workflow_dispatch`)로 시작 — 자동 배포가 필요해지면 `push`/`pull_request` 트리거 추가
- OIDC 기반 자격증명 사용 (장기 액세스 키 미보관)
- CI에서 호출하는 명령은 로컬에서 쓰는 `make` 타겟과 **완전히 동일**해야 함 (로컬/CI 불일치 방지)

### 템플릿
```yaml
name: (Dev) Deploy to AWS Lambda

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: astral-sh/setup-uv@v5
        with:
          python-version: "3.13"

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-2

      - name: Build
        run: make build

      - name: Deploy
        run: make deploy FUNCTION_NAME=${{ secrets.LAMBDA_FUNCTION_NAME }}
```

### 대체 구현
- AWS가 아니면 `configure-aws-credentials` 스텝을 해당 클라우드의 OIDC 액션(`google-github-actions/auth`, `azure/login` 등)으로 교체
- 나머지(`actions/checkout`, `make build`, `make deploy`)는 그대로 유지

---

## 7. 처음부터 만들 때 실행 순서 (Step by Step)

1. `mkdir -p app .github/workflows`
2. `app/__init__.py` 빈 파일 생성
3. `app/main.py` 작성 (섹션 1 템플릿, health check 라우트 1개로 시작)
4. `pyproject.toml` 작성 (섹션 4 템플릿, 런타임 의존성 3개)
5. `uv sync`로 로컬 환경 구성 후 `make dev`로 FastAPI 정상 기동 확인 (이 시점엔 Makefile에 `dev` 타겟만 있어도 됨)
6. `app/config.py` 작성 (섹션 2 템플릿) — 처음엔 `.env` 버전으로 시작해도 무방, 나중에 SSM으로 교체 가능
7. `handler.py` 작성 (섹션 3 템플릿)
8. `pyproject.toml`에 배포 어댑터(`mangum`) 의존성 추가
9. `Makefile`에 `build`/`deploy` 타겟 추가 (섹션 5 템플릿)
10. 로컬에서 `make build` 실행 → `lambda.zip` 생성 확인
11. AWS Lambda 함수 콘솔/CLI로 함수 자체를 미리 생성 (IaC 없는 구조이므로 함수 존재는 선행 조건)
12. `make deploy FUNCTION_NAME=...`로 1회 수동 배포 검증
13. `.github/workflows/dev.yaml` 작성 (섹션 6 템플릿), GitHub Secrets에 `AWS_ROLE_ARN`, `LAMBDA_FUNCTION_NAME` 등록
14. Actions 탭에서 `workflow_dispatch` 수동 실행으로 CI 배포 검증

이 순서를 따르면 "로컬에서 되는 게 배포에서도 그대로 된다"는 것을 각 단계마다 확인하면서 진행할 수 있습니다.

---

## 8. 불변 조건 요약 (이 구조를 "복제"한 것인지 판단하는 기준)

다른 프로젝트에 이 아키텍처를 적용했을 때, 아래 5가지가 모두 성립해야 "같은 아키텍처"라고 할 수 있습니다.

1. 비즈니스 로직(`app/`)에 배포 플랫폼 SDK import가 전혀 없다
2. 배포 어댑터(`handler.py`)는 로직 없이 wrapping만 한다
3. 설정 로더는 소스가 무엇이든 `dict` 하나를 반환하는 함수로 캡슐화되어 있다
4. `make dev`로 띄운 앱과 배포된 앱이 같은 `app` 객체를 공유한다 (분기 코드 없음)
5. 빌드(`build`)와 배포(`deploy`)가 분리된 단계이며, CI와 로컬이 동일한 명령을 사용한다
