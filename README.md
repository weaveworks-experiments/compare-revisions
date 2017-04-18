# compare-revisions

[![Circle CI](https://circleci.com/gh/jml/compare-revisions/tree/master.svg?style=shield)](https://circleci.com/gh/jml/compare-revisions/tree/master)

Do you have a "staging" Kubernetes cluster and a "production" Kubernetes
cluster and want to see what's deployed to staging, but not to production?

`compare-revisions` is a simple web service that you can deploy to your
staging cluster that will tell you what's on staging but not on prod.

It does this by assuming that there exists a simple mapping from image *names*
to Git repositories, and from image *tags* to Git revisions.

## Example

This configuration will pull from a configuration repository on Github
(`my-org/service-config`) every minute and compare the images found under the
`k8s/dev` path to the corresponding images in the `k8s/prod` path.

When it finds `weaveworks/cortex-distributor` images, it will apply a regular
expression to extract the revision from the image tag, assuming that the
metric tag is of the form `master-1ab2c3d`.

It will then display the top-level (i.e. `--first-parent`) revisions from the
Git log, including only those revisions that touch the given paths.

```yaml
config-repo:
  url: git@github.com:my-org/service-config.git
  poll-interval: 1m
  source-env:
    name: dev
    path: k8s/dev
  target-env:
    name: prod
    path: k8s/prod

images:
  weaveworks/cortex-distributor:
    git-url: git@github.com:weaveworks/cortex.git
    image-to-revision-policy: weaveworks
    paths:
      - cmd/distributor
      - distributor
      - ring
      - util

revision-policies:
  weaveworks:
    type: regex
    match: ^master-([0-9a-f]+)$
    output: \1
```

## How to run it

### Natively

Build and install the code with `stack install` and then run with:

    compare-revisions --port 8080 --config-file config.yaml --git-repo-dir /var/run/compare-revisions

This will start a server that you can reach at http://localhost:8080/

### With Docker

Create a Docker image with:

    make

The last line of successful `make` output will be the name of the image, e.g.
`compare-revisions:master-1a2b3cd`.

You can then run the image like so:

    docker run -ti -p 8080:80 -v /path/to/config:/data \
        compare-revisions:master-1a2b3cd \
          --port 80 \
          --config-file \
          /data/config.yaml

And you can reach the server at http://localhost:8080/ if you are running
Docker natively. If you're on a Mac and
using [Docker Machine](https://docs.docker.com/machine/), you can run:

    open http://$(docker-machine ip):8080/

To browse to the running server.
