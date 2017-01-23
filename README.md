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
