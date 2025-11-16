

# docker build -t liuyenhui/dono-sample:v1 .

# Use the official Deno image as the base image
FROM denoland/deno:2.5.6

# Set the working directory inside the container
WORKDIR /app

# Copy the application files into the container
COPY . .

# Compile the Deno application
RUN deno compile --allow-net main.ts -o main

# Expose the port the HTTP server will run on
EXPOSE 8000

# Command to run the compiled application
CMD ["./main"]