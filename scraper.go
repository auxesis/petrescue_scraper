package main

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/PuerkitoBio/goquery"
	"github.com/auxesis/petrescue_scraper/scraperwiki"
	"github.com/fatih/structs"
)

type animal struct {
	URL   string
	Name  string
	Breed string
}

// FatalIfError logs and exits if error
func FatalIfError(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func baseURI() *url.URL {
	u, err := url.Parse("https://www.petrescue.com.au/listings/search/dogs?interstate=true&page=1&per_page=60&postcode%5Bdistance%5D=50&postcode%5Bpostcode%5D=2256&state_id%5B%5D=1")
	FatalIfError(err)
	return u
}

func index() []animal {
	var animals []animal

	p := 1

	for {
		u := baseURI()
		q := u.Query()
		q.Set("page", strconv.Itoa(p))
		u.RawQuery = q.Encode()

		as := scrapeSearchResultsPage(u.String())
		if len(as) == 0 {
			break
		}
		animals = append(animals, as...)
		p++
	}
	return animals
}

func scrapeSearchResultsPage(url string) (animals []animal) {
	// Request the HTML page.
	res, err := http.Get(url)
	FatalIfError(err)

	defer res.Body.Close()
	if res.StatusCode != 200 {
		log.Fatalf("status code error: %d %s", res.StatusCode, res.Status)
	}

	// Load the HTML document
	doc, err := goquery.NewDocumentFromReader(res.Body)
	FatalIfError(err)

	// Find the review items
	doc.Find("div.search-results article.cards-listings-preview").Each(func(i int, s *goquery.Selection) {
		name := strings.TrimSpace(s.Find("header h3").Text())
		link, _ := s.Find("a.cards-listings-preview__content").Attr("href")
		animals = append(animals, animal{URL: link, Name: name})
	})

	return animals
}

func animalsToData(as []animal) (d []map[string]interface{}) {
	for _, a := range as {
		d = append(d, structs.Map(a))
	}
	return d
}

func scrape(a *animal) {
	// Request the HTML page.
	res, err := http.Get(a.URL)
	FatalIfError(err)

	defer res.Body.Close()
	if res.StatusCode != 200 {
		log.Fatalf("status code error: %d %s", res.StatusCode, res.Status)
	}

	// Load the HTML document
	doc, err := goquery.NewDocumentFromReader(res.Body)
	FatalIfError(err)

	// Find the review items
	e := doc.Find("h3.pet-listing__content__breed").First()
	a.Breed = strings.TrimSpace(e.Text())
}

func main() {
	animals := index()
	for i, a := range animals {
		scrape(&a)
		animals[i] = a
	}

	fmt.Printf("len: %d\n", len(animals))

	keys := []string{"URL"}
	data := animalsToData(animals)
	tableName := "data"
	scraperwiki.SaveSqlite(keys, data, tableName)
	//scrape()
}
