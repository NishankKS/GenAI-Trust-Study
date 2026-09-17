f <- list.files("data/cache/openai_gpt-oss-120b", "[.]rds$", full.names = TRUE)[1]
x <- readRDS(f)
cat("class:", class(x), "\n"); cat("names:", paste(names(x), collapse=", "), "\n")
str(x, max.level = 2, list.len = 5)
