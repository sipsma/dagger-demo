package main

import (
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
)

func main() {
	if len(os.Args) < 2 || len(os.Args[1]) == 0 {
		fmt.Println("Provide a URL as an arg")
		os.Exit(1)
	}
	url := os.Args[1]

	// do an HTTP GET request on the URL and print the body
	resp, err := http.Get(url)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		panic(err)
	}
	fmt.Println(string(body))
}
