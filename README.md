# Unlocked Docuseal

# Simple Instruction 
## Step 1: Run the Docuseal Docker Container
Run the Docker Container
Start the docuseal container and expose port 3009:
```bash
docker run --name docuseal -p 3009:3000 -v "$(pwd):/data" docuseal/docuseal
```

## Step 2: Copy Configuration Files into the Container
Copy the necessary source files into the running container:
```bash
docker cp ./docuseal_src/app/controllers/. docuseal:/app/app/controllers/
docker cp ./docuseal_src/config/. docuseal:/app/config/
```

## Step 3: Start the Puma Server Inside the Container
Run the puma server in the docuseal container:
```bash
docker exec -it docuseal /app/bin/bundle exec puma -C /app/config/puma.rb --dir /app
```
This will start the application, making it available at http://localhost:3009.

## Step 4: Create a New Template Using the API
To create a new template, use the following curl command to send a POST request. Replace X-Auth-Token with your authentication token.

```bash
curl --request POST \
  --url http://localhost:3009/api/templates \
  --header 'X-Auth-Token: S2FWj9AaQ4DCSSEpoBzrhhwb6JuPTavmKpSR9QDeNri' \
  --header 'content-type: application/json' \
  --data '{"url": "https://pdfobject.com/pdf/sample.pdf"}'
```
Ensure that X-Auth-Token is correct for authentication. 