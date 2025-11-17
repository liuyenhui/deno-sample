
# docker build -t liuyenhui/dono-sample:v1 . --no-cache
# docker run -d -p 8080:80 --name deno-sample liuyenhui/dono-sample:v1
# Use the official Deno image as the base image
FROM nginx:1.16-alpine

# Set the working directory inside the container

# Copy the application files into the container
COPY www /usr/share/nginx/html


# Compile the Deno application
RUN echo "Deno sample app deployed with Nginx"

# Expose the port the HTTP server will run on
EXPOSE 80

# Command to run the compiled application
CMD ["nginx", "-g", "daemon off;"]