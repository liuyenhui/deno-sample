function main() {
    Deno.serve((_req: Request) => {
        return new Response("Hello from Deno!");
    });
    // port 8000 by default
    console.log("Server running on http://localhost:8000");

}

main();