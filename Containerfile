ARG FLAVOR=cpu

# -- Stage 1: Build docs inputs
# FIXME(S2I): This stage uses Fedora temporarily because operators docs generation
# requires pandoc + asciidoctor packages not consistently available in our UBI
# build environment. Once operators docs are migrated to Markdown upstream,
# drop these tools and move this stage back to UBI.
FROM registry.fedoraproject.org/fedora:40 as docs-builder

ARG BUILD_UPSTREAM_DOCS=true
ARG BUILD_OPERATORS_DOCS=false
ARG NUM_WORKERS=1
ARG OS_PROJECTS
ARG OS_API_DOCS=false
ARG PRUNE_PATHS=""
ARG RHOSO_CA_CERT_URL=""
ARG RHOSO_DOCS_GIT_URL=""
ARG RHOSO_DOCS_GIT_BRANCH="main"

ENV NUM_WORKERS=$NUM_WORKERS
ENV OS_PROJECTS=$OS_PROJECTS
ENV OS_API_DOCS=$OS_API_DOCS
ENV PRUNE_PATHS=$PRUNE_PATHS
ENV RHOSO_CA_CERT_URL=$RHOSO_CA_CERT_URL
ENV RHOSO_DOCS_GIT_URL=$RHOSO_DOCS_GIT_URL
ENV RHOSO_DOCS_GIT_BRANCH=$RHOSO_DOCS_GIT_BRANCH
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV LC_CTYPE=en_US.UTF-8

USER 0
WORKDIR /rag-content
COPY pyproject.toml README.md /rag-content/
COPY src /rag-content/src
COPY scripts /rag-content/scripts
COPY .s2i/builddeps.txt /tmp/builddeps.txt

# Install system build dependencies from builddeps.txt
RUN pkgs=$(grep -v '^#' /tmp/builddeps.txt | grep -v '^$' | tr '\n' ' ') && \
    if [ -n "${pkgs}" ]; then dnf -y install ${pkgs}; fi && \
    localedef -i en_US -f UTF-8 en_US.UTF-8 || true && \
    dnf clean all

RUN python3 -m pip install . tox

# TODO(S2I): This stage currently generates docs by pulling/building upstream OpenStack
# content at image-build time. For a full S2I artifact workflow, this should move to a
# pre-build artifact ingestion process once the S2I team defines onboarding for
# non-OpenStack Service images.
# Generate upstream plaintext docs when requested
RUN if [ "$BUILD_UPSTREAM_DOCS" = "true" ]; then \
        ./scripts/get_openstack_plaintext_docs.sh; \
    fi

# FIXME(S2I): This stage still fetches downstream docs and optional CA material via URL
# during image build. For a real S2I flow, these inputs should arrive as validated external
# artifacts (similar to .s2i artifacts) once the S2I team provides a process for onboarding
# non-OpenStack Service images.
# Clone downstream docs repo when provided
RUN if [ -n "$RHOSO_DOCS_GIT_URL" ]; then \
        if [ -n "$RHOSO_CA_CERT_URL" ]; then \
            echo "Adding custom RHOSO CA certificate from $RHOSO_CA_CERT_URL"; \
            curl -o ca.pem "${RHOSO_CA_CERT_URL}"; \
            git clone -c http.sslCAInfo=ca.pem -v --depth=1 --single-branch --branch "$RHOSO_DOCS_GIT_BRANCH" "$RHOSO_DOCS_GIT_URL" rag-docs; \
        else \
            GIT_SSL_NO_VERIFY=true git clone -v --depth=1 --single-branch --branch "$RHOSO_DOCS_GIT_BRANCH" "$RHOSO_DOCS_GIT_URL" rag-docs; \
        fi; \
    fi

# Generate operators docs from openstack-operator repo when requested
RUN if [ "$BUILD_OPERATORS_DOCS" = "true" ]; then \
        ./scripts/get_openstack_operators_docs.sh; \
        mkdir -p rag-docs; \
        rm -rf rag-docs/openstack-operators-docs-markdown; \
        cp -r openstack-operators-docs-markdown rag-docs/openstack-operators-docs-markdown; \
    fi

# -- Stage 2: Build vector DB + embedding models
FROM quay.io/lightspeed-core/rag-content-${FLAVOR}:latest as embeddings-builder

ARG FLAVOR=cpu
ARG BUILD_UPSTREAM_DOCS=true
ARG BUILD_OPERATORS_DOCS=false
ARG DOCS_LINK_UNREACHABLE_ACTION=warn
ARG OS_VERSION=2026.1
ARG INDEX_NAME=os-docs-${OS_VERSION}
ARG NUM_WORKERS=1
ARG RHOSO_DOCS_GIT_URL=""
ARG VECTOR_DB_TYPE="faiss"
ARG RHOSO_IGNORE_LIST=""
ARG RHOSO_DOCS_EXTRA_DOCS=""

ENV OS_VERSION=$OS_VERSION
ENV LD_LIBRARY_PATH=""
ENV PYTHONPATH=/rag-content/src

USER 0
WORKDIR /rag-content

COPY --from=docs-builder /rag-content /rag-content

RUN if [ "$FLAVOR" = "gpu" ]; then \
        python -c "import torch, sys; available=torch.cuda.is_available(); print(f'CUDA is available: {available}'); sys.exit(0 if available else 1)"; \
    fi && \
    if [ "$BUILD_UPSTREAM_DOCS" = "true" ]; then \
        FOLDER_ARG="--folder openstack-docs-plaintext"; \
    fi && \
    if [ -n "$RHOSO_DOCS_GIT_URL" ]; then \
        if [ -n "$RHOSO_DOCS_EXTRA_DOCS" ]; then \
            FOLDER_ARG="$FOLDER_ARG --extra-folder $RHOSO_DOCS_EXTRA_DOCS"; \
        fi; \
        if [ "$BUILD_OPERATORS_DOCS" = "true" ]; then \
            FOLDER_ARG="$FOLDER_ARG --operators-folder rag-docs/openstack-operators-docs-markdown"; \
        fi; \
    fi && \
    if [ -z "$FOLDER_ARG" ]; then \
        echo "Error: No documentation sources enabled"; \
        exit 1; \
    fi && \
    python -m openstack_lightspeed_rag_content.generate_embeddings_openstack \
        --output ./vector_db/ \
        --model-dir embeddings_model \
        --model-name ${EMBEDDING_MODEL} \
        --index ${INDEX_NAME} \
        --workers ${NUM_WORKERS} \
        --unreachable-action ${DOCS_LINK_UNREACHABLE_ACTION} \
        --ignore-list ${RHOSO_IGNORE_LIST} \
        --vector-store-type $VECTOR_DB_TYPE \
        ${FOLDER_ARG}

# Copy pre-fetched OKP model artifact from build context
COPY .s2i/artifacts/okp_embeddings_model /rag-content/okp_embeddings_model

# -- Stage 3: Artifact image (files only)
FROM registry.access.redhat.com/ubi10/ubi-minimal:latest as artifact
COPY --from=embeddings-builder /rag-content/vector_db /rag/vector_db/os_product_docs
COPY --from=embeddings-builder /rag-content/embeddings_model /rag/embeddings_model
COPY --from=embeddings-builder /rag-content/okp_embeddings_model /rag/okp_embeddings_model

ARG INDEX_NAME
ENV INDEX_NAME=${INDEX_NAME}

RUN mkdir /licenses
COPY LICENSE /licenses/

LABEL description="Red Hat OpenStack Lightspeed RAG content"
USER 65532:65532
