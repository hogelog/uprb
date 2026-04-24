# s3-ls

Example S3 ls command gem.

## Usage

```bash
s3-ls s3://bucket[/prefix]
```

## Packing with uprb

`aws-sdk-core` triggers rubygems vendored stdlib and has lazy `require` calls in its credential provider chain that won't be captured unless pre-required at pack time. To pack a runnable executable, embed rubygems and force-load the lazy paths:

```bash
uprb gem pack s3-ls --with-rubygems \
  -raws-sdk-core \
  -raws-sdk-core/shared_credentials \
  -raws-sdk-core/ini_parser \
  --path ~/local/bin/
```

The packed binary is still tied to the credential-resolution path observed at pack time. If runtime falls through to a provider whose lazy requires weren't captured (e.g. a new provider in a newer `aws-sdk-core`), repack with additional `-r` flags.
