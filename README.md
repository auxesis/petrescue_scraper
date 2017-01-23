Scraper for [PetRescue](https://www.petrescue.com.au/).

The scraper fetches animal listings on the PetRescue website.

This scraper [runs on Morph](https://morph.io/auxesis/petrescue_scraper). To get started [see Morph's documentation](https://morph.io/documentation).

## Developing

Ensure you have Git, Ruby, and Bundler set up the scraper locally, then run:

```
git clone https://github.com/auxesis/petrescue_scraper.git
cd petrescue_scraper
bundle install
```

Then run the scraper:

```
bundle exec ruby scraper.rb
```

## Control what species are scraped with MORPH_SPECIES

You can use the `MORPH_SPECIES` environment variable to control what species are scraped from PetRescue:

```
MORPH_SPECIES="dogs" bundle exec ruby scraper.rb
```

Valid options are `dogs`, `cats`, `other`, or any combination thereof.

The default species to scrape are `dogs cats other`.

## The scraper aggressively caches to the filesystem

The scraper makes _a lot_ of HTTP requests when scraping.

The scraper will make a HTTP request for:

 - Each pages of search results for each species (at the time of writing, there are > 400 pages of search results for cats alone)
 - Each animal listing (at the time of writing, there are over 8,500 listings on PetRescue)

In an effort to minimise the number of requests to the PetRescue website, the scraper uses a filesystem cache by default.

You can control this behaviour by setting these environment variables:

 - `MORPH_CACHE_INDEX` controls if the index is read from cache. Default is `true`.
 - `MORPH_CACHE_DETAILS` controls if each listing is read from cache. Default is `true`.

These settings are most useful when debugging or testing behaviour locally. For example, to use an index cache, but bypass the details cache:

```
MORPH_CACHE_INDEX=true MORPH_CACHE_DETAILS=false bundle exec ruby scraper.rb
```

When the scraper is run on Morph, the underlying filesystem is ephemeral on every run. This means that while the scraper caches during its run, all the data is discarded at the end of the run.
