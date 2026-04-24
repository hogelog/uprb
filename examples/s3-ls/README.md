# s3-ls

Example S3 ls command gem.

## Usage

```bash
s3-ls s3://bucket[/prefix]
```

## Packing with uprb

`aws-sdk-core` pulls in rubygems vendored stdlib, so embed rubygems with `--with-rubygems`. Its credential provider chain uses runtime-only interpolated requires (e.g. `aws-sdk-core/json/#{name}_engine`), so pack in `--dynamic` mode so the entry actually runs and those requires fire:

```bash
uprb gem pack s3-ls --with-rubygems --dynamic --path ~/local/bin/
```

`--dynamic` also augments its trace with a static walk of every reachable `.rb`, so literal requires in unexecuted credential-provider branches get embedded too. If a runtime path still falls through to something that wasn't observed or statically reachable, repack with additional `-r` flags for the missing libs.
